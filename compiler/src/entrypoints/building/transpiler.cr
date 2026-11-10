require "../../../../fragments/vendor/libpftrace/bindings/crystal/src/pftrace"
require "./trace_helper"
require "../../webcomponents/component_generator"
require "../../gvm/mrbc_compiler"
require "../../tree-sitter/instance_var_analyzer"
require "../../html/attribute_conditional_extractor"
require "../../html/attribute_hash_extractor"
require "../../html/event_argument_extractor"
require "../../ruby/attribute_method_generator"
require "../../ruby/attribute_hash_generator"

class Compiler
  include TraceHelper

  def initialize
  end

  def transpile_directory(input_dir : String, output_dir : String, builder_man : BuilderMan, trace : Pftrace::Trace? = nil, sequence_id : UInt32 = 1_u32)
    build_dir = builder_man.build_dir
    puts "inputDir:'#{input_dir}', outDir:'#{output_dir}', build_dir:'#{build_dir}'"

    components = [] of MochiComponent
    i = 1

    nr_files = 0
    done_channel = Channel(Nil).new

    trace_slice(trace, "ProcessComponents", sequence_id) do
      Dir.glob(Path[input_dir, "**", "*.rb"].to_s) do |path|
        if File.file?(path) && path.ends_with?(".rb")
          nr_files += 1
          spawn do
            begin
              puts "Processing #{path}"
              content = File.read(path)
              absolute_path = Path[path].expand.to_s

              rb_file = File.read(absolute_path)
              component = transpile_component(rb_file, i, absolute_path)

              i += 1
              if component
                components << component
              end
              done_channel.send(nil)
            end
          rescue ex
            puts "Error processing file #{path}: #{ex.message}\n#{ex.inspect_with_backtrace}"
          end
        end
      end

      nr_files.times do |i|
        done_channel.receive
      end
    end

    puts "Done with preparing components for transpilation"

    trace_slice(trace, "AssembleJS", sequence_id) do
      puts "Writing #{build_dir}/bundle.js"
      File.write("#{build_dir}/bundle.js", "console.log('Mochi booted.');\n")
    end

    trace_slice(trace, "EmitBytecode", sequence_id) do
      compiler = MrbcCompiler.new
      compiler.compile(components, output_dir)
      compiler.warnings.each { |warning| STDERR.puts "Warning: #{warning}" }
      puts "Wrote #{compiler.chi_paths.size} component(s) and #{compiler.manifest_path}"
    end

    puts "Transpilation finished"
  end

  private def transpile_component(rb_file : String, i : Int32, absolute_path : String)
    cls_name = RubyUnderstander.class_name(rb_file)

    print_cmp_start_separator(cls_name, i)
    puts "ClassName:'#{cls_name}'"

    if cls_name.blank?
      return
    end

    methods : Hash(String, RubyDef) = RubyUnderstander.extract_method_bodies(rb_file, cls_name)
    # puts methods

    amped_ruby_code = rb_file
    if methods.has_key?("css")
      # css = methods["css"]
      # puts "css:#{css.body[1...css.body.size - 1]}"
      imports = RubyUnderstander.get_imports(rb_file)
      css = RubyUnderstander.extract_raw_string_from_def_body(methods["css"].body, "css")
      html = RubyUnderstander.extract_raw_string_from_def_body(methods["html"].body, "html")

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

      tag_name = RubyUnderstander.get_cmp_name(rb_file, cls_name)

      if tag_name
        manifest = ComponentGenerator.new.generate(
          mochi_cmp_name = cls_name,
          tag_name = tag_name.not_nil!,
          css,
          html = each_result.html,
          reactables,
          {} of String => String,
          conditional_result.conditionals,
          each_result.each_blocks
        )

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
    else
      puts "Skipping '#{cls_name}', no css method"
    end
    print_cmp_end_seperator(cls_name, i)
  end
end
