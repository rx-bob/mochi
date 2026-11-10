require "../../../../fragments/vendor/libpftrace/bindings/crystal/src/pftrace"
require "./trace_helper"
require "../../webcomponents/component_generator"
require "../../gvm/mrbc_compiler"
require "../../tree-sitter/instance_var_analyzer"
require "../../ruby/ruby_understander"
require "../../html/attribute_conditional_extractor"
require "../../html/attribute_hash_extractor"
require "../../html/event_argument_extractor"
require "../../html/conditional_processor"
require "../../html/each_processor"
require "../../ruby/attribute_method_generator"
require "../../ruby/attribute_hash_generator"
require "../../ruby/conditional_method_generator"
require "../../ruby/each_method_generator"

class Compiler
  include TraceHelper

  MAX_TRACKED_IVARS = 256
  BINDING_LITERALS  = ["true", "false", "nil", "self"]

  def initialize
  end

  def transpile_directory(input_dir : String, output_dir : String, builder_man : BuilderMan, trace : Pftrace::Trace? = nil, sequence_id : UInt32 = 1_u32)
    puts "inputDir:'#{input_dir}', outDir:'#{output_dir}', build_dir:'#{builder_man.build_dir}'"

    components = [] of MochiComponent
    i = 1

    nr_files = 0
    done_channel = Channel(Nil).new
    errors = [] of String

    trace_slice(trace, "ProcessComponents", sequence_id) do
      Dir.glob(Path[input_dir, "**", "*.rb"].to_s) do |path|
        if File.file?(path) && path.ends_with?(".rb")
          nr_files += 1
          spawn do
            begin
              puts "Processing #{path}"
              absolute_path = Path[path].expand.to_s

              rb_file = File.read(absolute_path)
              component = transpile_component(rb_file, i, absolute_path)

              i += 1
              if component
                components << component
              end
            rescue ex
              errors << "Error processing file #{path}: #{ex.message}"
            ensure
              done_channel.send(nil)
            end
          end
        end
      end

      nr_files.times do
        done_channel.receive
      end
    end

    unless errors.empty?
      raise "Component transpilation failed:\n#{errors.join("\n")}"
    end

    puts "Done with preparing components for transpilation"

    trace_slice(trace, "EmitBytecode", sequence_id) do
      compiler = MrbcCompiler.new
      compiler.compile(components, output_dir)
      compiler.warnings.each { |warning| STDERR.puts "Warning: #{warning}" }
      puts "Wrote #{compiler.chi_paths.size} component(s) and #{compiler.manifest_path}"
    end

    puts "Transpilation finished"
  end

  def transpile_component(rb_file : String, i : Int32, absolute_path : String)
    cls_name = RubyUnderstander.class_name(rb_file)

    print_cmp_start_separator(cls_name, i)
    puts "ClassName:'#{cls_name}'"

    if cls_name.blank?
      return
    end

    methods : Hash(String, RubyDef) = RubyUnderstander.extract_method_bodies(rb_file, cls_name)
    tag_name = RubyUnderstander.get_cmp_name(rb_file, cls_name)
    html_method = methods["html"]?

    # A component is identified by its tag name or its html method. Classes
    # with neither marker are ordinary Ruby classes and stay out of the bundle.
    if tag_name.nil? && html_method.nil?
      puts "Skipping '#{cls_name}', no @tag_name or html method"
      print_cmp_end_seperator(cls_name, i)
      return
    end

    if tag_name.nil?
      raise "Component '#{cls_name}' defines an html method but no @tag_name"
    end

    if html_method.nil?
      raise "Component '#{cls_name}' defines @tag_name but no html method"
    end

    imports = RubyUnderstander.get_imports(rb_file)
    css = if css_method = methods["css"]?
            RubyUnderstander.extract_raw_string_from_def_body(css_method.body, "css")
          else
            ""
          end
    html = RubyUnderstander.extract_raw_string_from_def_body(html_method.body, "html")

    # Remove html and css before injecting helpers. Their string bodies may
    # contain `{end}`, which must never be mistaken for the class terminator.
    amped_ruby_code = RubyUnderstander.remove_methods(rb_file, cls_name, ["html", "css"])

    # 1. Extract hash attributes BEFORE anything else (since {{...}} breaks Lexbor parsing)
    attr_hash_result = AttributeHashExtractor.process(html)
    html = attr_hash_result.html

    amped_ruby_code = AttributeHashGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      attr_hash_result.hashes
    )

    # 2. Extract attribute conditionals
    attr_cond_result = AttributeConditionalExtractor.process(html)
    html = attr_cond_result.html

    amped_ruby_code = AttributeMethodGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      attr_cond_result.conditionals
    )

    # 3. Extract event handler arguments into data- attributes
    html = EventArgumentExtractor.process(html)

    # Analyze instance variables to determine reactables automatically
    vars = TreeSitter::InstanceVarAnalyzer.analyze(rb_file)
    validate_ivar_capacity(cls_name, vars)

    # Filter for variables that are either:
    # - Bound in the HTML (used in {}) AND are actual state (written/mutated)
    # - Mutated via attr_accessor/attr_writer
    # - Written to outside of the constructor (state)
    reactive_vars = vars.select do |v|
      (v.is_bound && (v.writes > 0 || v.attr_mutated)) || v.attr_mutated || v.written_outside_constructor
    end

    reactables_arr = reactive_vars.map { |v| v.name.sub(/^@/, "") }

    # Add the new attribute conditionals and hashes to reactables so they are tracked
    attr_cond_result.conditionals.each do |cond|
      reactables_arr << "__mochi_attr_cond_#{cond.id}"
    end
    attr_hash_result.hashes.each do |hash_cond|
      reactables_arr << "__mochi_attr_hash_#{hash_cond.id}"
    end

    # puts "Computed reactables for #{cls_name}: #{reactables_arr}"
    reactables = if reactables_arr.empty?
                   "[]"
                 else
                   "['#{reactables_arr.join("', '")}']"
                 end

    # puts "reactables: #{reactables}"

    conditional_result = ConditionalProcessor.process(html)

    amped_ruby_code = ConditionalMethodGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      conditional_result.conditionals
    )

    each_result = EachProcessor.process(conditional_result.html)

    amped_ruby_code = EachMethodGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      each_result.each_blocks
    )

    manifest = ComponentGenerator.new.generate(
      mochi_cmp_name = cls_name,
      tag_name = tag_name.not_nil!,
      css,
      html = each_result.html,
      reactables,
      {} of String => String,
      conditional_result.conditionals,
      each_result.each_blocks,
      methods.keys
    )

    validate_binding_methods(cls_name, manifest.bindings, methods.keys, rb_file)

    rewritten_ruby_code = ComponentGenerator.new.rewrite_ruby(
      amped_ruby_code,
      cls_name,
      manifest,
      methods
    )

    print_cmp_end_seperator(cls_name, i)
    return MochiComponent.new(
      absolute_path,
      cls_name,
      imports,
      ruby_code = rewritten_ruby_code,
      manifest,
      manifest.html_template,
      css
    )
  end

  private def validate_binding_methods(
    cls_name : String,
    bindings : Array(BindingDescriptor),
    method_names : Array(String),
    rb_file : String,
  ) : Nil
    readable = Set(String).new
    method_names.each { |name| readable << name }
    RubyUnderstander.attribute_readers(rb_file, cls_name).each { |name| readable << name }

    bindings.each do |binding|
      expression = binding.getter_expr
      next unless expression

      name = expression.strip
      next if name.starts_with?("__mochi_")
      next unless name =~ /\A[a-z_][a-zA-Z0-9_]*[?!]?\z/
      next if BINDING_LITERALS.includes?(name)
      next if readable.includes?(name)

      raise "Component '#{cls_name}' binds undefined method '#{name}' in #{binding.template_text.inspect}; use '@#{name}' for an instance variable"
    end
  end

  private def validate_ivar_capacity(cls_name : String, vars : Array(TreeSitter::InstanceVarAnalyzer::VariableInfo)) : Nil
    ivars = vars.map(&.name).reject { |name| name == "@tag_name" }.uniq
    return if ivars.size <= MAX_TRACKED_IVARS

    raise "Component '#{cls_name}' declares #{ivars.size} instance variables, exceeding the GVM limit of #{MAX_TRACKED_IVARS}"
  end
end
