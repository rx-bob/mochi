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

  @ruby_parser : TreeSitter::RubyParser

  def initialize
    @ruby_parser = TreeSitter::RubyParser.new
  end

  def transpile_directory(input_dir : String, output_dir : String, builder_man : BuilderMan, trace : Pftrace::Trace? = nil, sequence_id : UInt32 = 1_u32)
    puts "inputDir:'#{input_dir}', outDir:'#{output_dir}', build_dir:'#{builder_man.build_dir}'"

    components = [] of MochiComponent
    prelude_files = [] of Tuple(String, String)
    i = 1

    errors = [] of String

    t_start = Time.monotonic
    trace_slice(trace, "ProcessComponents", sequence_id) do
      paths = Dir.glob(Path[input_dir, "**", "*.rb"].to_s).select { |p| File.file?(p) && p.ends_with?(".rb") }.sort
      paths.each do |path|
        begin
          puts "Processing #{path}"
          absolute_path = Path[path].expand.to_s

          rb_file = File.read(absolute_path)
          component = transpile_component(rb_file, i, absolute_path)

          i += 1
          if component
            components << component
          elsif !rb_file.strip.empty?
            prelude_files << {absolute_path, rb_file}
          end
        rescue ex
          errors << "Error processing file #{path}: #{ex.message}"
        end
      end
    end

    unless errors.empty?
      raise "Component transpilation failed:\n#{errors.join("\n")}"
    end

    puts "Done with preparing components for transpilation (#{Time.monotonic})"
    prelude_code = prelude_files.sort_by(&.[0]).map(&.[1]).join("\n\n")

    trace_slice(trace, "EmitBytecode", sequence_id) do
      compiler = MrbcCompiler.new
      compiler.compile(components, output_dir, prelude_code)
      compiler.warnings.each { |warning| STDERR.puts "Warning: #{warning}" }
      puts "Wrote #{compiler.chi_paths.size} component(s) and #{compiler.manifest_path}"
    end

    puts "Transpilation finished"
  end

  def transpile_component(rb_file : String, i : Int32, absolute_path : String)
    tree = @ruby_parser.parse(rb_file)
    root = tree.root_node

    cls_name = RubyUnderstander.class_name(root)

    print_cmp_start_separator(cls_name, i)
    puts "ClassName:'#{cls_name}'"

    if cls_name.blank?
      return
    end

    methods : Hash(String, RubyDef) = RubyUnderstander.extract_method_bodies(root, cls_name, rb_file)
    tag_name = RubyUnderstander.get_cmp_name(root, cls_name)
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

    unless tag_name.includes?("-")
      raise "Component '#{cls_name}' has invalid @tag_name '#{tag_name}': custom element tag names must contain a hyphen"
    end

    if html_method.nil?
      raise "Component '#{cls_name}' defines @tag_name but no html method"
    end

    imports = RubyUnderstander.get_imports(root)
    css = if css_method = methods["css"]?
            css_method.raw_string || RubyUnderstander.extract_raw_string_from_def_body(css_method.body, "css")
          else
            ""
          end
    html = html_method.raw_string || RubyUnderstander.extract_raw_string_from_def_body(html_method.body, "html")

    # Remove html and css before injecting helpers. Their string bodies may
    # contain `{end}`, which must never be mistaken for the class terminator.
    amped_ruby_code = RubyUnderstander.remove_methods(root, rb_file, cls_name, ["html", "css"])

    # 1. Extract hash attributes BEFORE anything else (since {{...}} breaks Lexbor parsing)
    attr_hash_result = AttributeHashExtractor.process(html)
    html = ComponentGenerator.escape_double_braces(attr_hash_result.html)

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
    vars = TreeSitter::InstanceVarAnalyzer.analyze(root)
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

    reactables = if reactables_arr.empty?
                   "[]"
                 else
                   "['#{reactables_arr.join("', '")}']"
                 end

    conditional_result = ConditionalProcessor.process(html)

    amped_ruby_code = ConditionalMethodGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      conditional_result.conditionals
    )

    each_result = EachProcessor.process(conditional_result.html)

    generator = ComponentGenerator.new
    manifest = generator.generate(
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

    validate_binding_methods(cls_name, manifest.all_bindings, methods.keys, root)

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
    root : TreeSitter::Node,
  ) : Nil
    readable = Set(String).new
    method_names.each { |name| readable << name }
    RubyUnderstander.attribute_readers(root, cls_name).each { |name| readable << name }

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

  private def validate_binding_methods(
    cls_name : String,
    bindings : Array(BindingDescriptor),
    method_names : Array(String),
    rb_file : String,
  ) : Nil
    tree = @ruby_parser.parse(rb_file)
    validate_binding_methods(cls_name, bindings, method_names, tree.root_node)
  end

  private def validate_ivar_capacity(cls_name : String, vars : Array(TreeSitter::InstanceVarAnalyzer::VariableInfo)) : Nil
    ivars = vars.map(&.name).reject { |name| name == "@tag_name" }.uniq
    return if ivars.size <= MAX_TRACKED_IVARS

    raise "Component '#{cls_name}' declares #{ivars.size} instance variables, exceeding the GVM limit of #{MAX_TRACKED_IVARS}"
  end
end
