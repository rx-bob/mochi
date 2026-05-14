# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "fileutils"
require "pathname"

require_relative "../quickjs/opal_builder"
require_relative "../caching/cache"
require_relative "../webcomponents/component_generator"
require_relative "../tree_sitter/instance_var_analyzer"
require_relative "../html/attribute_conditional_extractor"
require_relative "../html/attribute_hash_extractor"
require_relative "../html/event_argument_extractor"
require_relative "../html/conditional_processor"
require_relative "../html/each_processor"
require_relative "../lexbor/bind_extractor"
require_relative "../ruby/attribute_method_generator"
require_relative "../ruby/attribute_hash_generator"
require_relative "../ruby/conditional_method_generator"
require_relative "../ruby/each_method_generator"
require_relative "../ruby/ruby_understander"
require_relative "../ruby/ruby_rewriter"
require_relative "../data_models/mochi_component"
require_relative "../data_models/ruby_def"

class Compiler
  extend T::Sig

  sig { void }
  def initialize
  end

  sig do
    params(
      input_dir: String,
      output_dir: String,
      builder_man: BuilderMan,
      sequence_id: Integer
    ).void
  end
  def transpile_directory(input_dir, output_dir, builder_man, sequence_id = 1)
    build_dir = builder_man.build_dir
    puts "inputDir:'#{input_dir}', outDir:'#{output_dir}', build_dir:'#{build_dir}'"

    components = [] #: Array<MochiComponent]
    i = 1
    rb_rewriter = RubyRewriter.new

    Dir.glob(File.join(input_dir, "**", "*.rb")) do |path|
      next unless File.file?(path) && path.end_with?(".rb")

      puts "Processing #{path}"
      absolute_path = File.expand_path(path)
      rb_file = File.read(absolute_path)

      begin
        component = transpile_component(rb_file, i, absolute_path)
        i += 1

        if component
          components << component

          src_dir = builder_man.ruby_src_dir
          lib_path = rb_rewriter.extract_lib_path(absolute_path)
          file_path = "#{src_dir}/#{lib_path}"
          puts "lib_path:#{lib_path}, src_dir:#{src_dir}, file_path:#{file_path}"

          if lib_path
            FileUtils.mkdir_p(File.dirname(file_path))
            File.write(file_path, component.ruby_code)
          end
        end
      rescue => e
        puts "Error processing file #{path}: #{e.message}\n#{e.backtrace&.join("\n") || ""}"
      end
    end

    rb_rewriter.comment_out_all_sorbet_signatures_in_dir("#{builder_man.ruby_src_dir}/lib")

    mochi_root = rb_rewriter.gen_mochi_ruby_root(components)
    File.write("#{builder_man.ruby_src_dir}/lib/Root.rb", mochi_root)

    puts "Done with preparing components for transpilation"
    puts "Transpiling..."
    transpiled_ruby_code_path = "#{build_dir}/ruby.js"

    puts "gems installed (skipped)"

    use_quickjs = true

    cache = T.let(Caching::Cache.new, Caching::Cache)

    transpiled_ruby_code = if use_quickjs
      builder = QuickJS::Opal::Builder.new(include_runtime: false)
      builder.add_stdlib("await")
      builder.add_stdlib("json")

      builder.add_raw_js("Opal.modules['sorbet-runtime'] = function(Opal) { return Opal.nil; };")
      builder.add_raw_js("Opal.modules['sorbet'] = function(Opal) { return Opal.nil; };")

      builder.compile("$LOAD_PATH.unshift('/lib'); $LOAD_PATH.unshift('lib'); $LOAD_PATH.unshift('./lib')", "lib_setup")
      builder.add_raw_js("Opal.load('lib_setup');")

      lib_dir = "#{builder_man.ruby_src_dir}/lib"
      src_dir = builder_man.ruby_src_dir
      puts "Scanning #{lib_dir} for source files..."

      if Dir.exist?(lib_dir)
        Dir.glob("#{lib_dir}/**/*.rb") do |full_path|
          next if full_path.end_with?("/Root.rb")

          code = File.read(full_path)
          rel_path_src = Pathname.new(full_path).relative_path_from(Pathname.new(src_dir)).to_s
          rel_path_lib = Pathname.new(full_path).relative_path_from(Pathname.new(lib_dir)).to_s

          if rel_path_lib == "mochi.rb"
            builder.compile_with_cache(code, rel_path_src, cache)
            builder.compile_with_cache(code, rel_path_lib, cache)
          elsif rel_path_lib.start_with?("sorbet-types/")
            builder.compile_with_cache(code, rel_path_src, cache)
          else
            builder.compile_with_cache(code, rel_path_lib, cache)
          end
        end
      else
        puts "ERROR: lib_dir does not exist: #{lib_dir}"
      end

      puts "Compiling Entry Point: lib/Root.rb (as main)"

      root_path = "#{lib_dir}/Root.rb"
      if File.exist?(root_path)
        builder.compile_with_cache(File.read(root_path), "lib/Root.rb", cache, requirable: false)
      else
        puts "ERROR: Root.rb not found at #{root_path}"
      end

      result = builder.build(nil)
      File.write(transpiled_ruby_code_path, result)
      builder.finalize
      result
    else
      puts "Using Opal CLI (Old Logic)..."
      # Old CLI path - not used in Ruby port
      T.let(File.read(transpiled_ruby_code_path), String)
    end

    cache.close

    components_js_code = ""
    components.each do |mochi_comp|
      components_js_code = components_js_code + "\n" + mochi_comp.web_component.js_code + "\n"
    end
    components_js_code = components_js_code + "\n" + "console.log('Mochi booted.');" + "\n"

    output = transpiled_ruby_code + "\n" + components_js_code
    puts "Writing #{build_dir}/bundle.js"
    File.write("#{build_dir}/bundle.js", output)

    puts "Transpilation finished"
  end

  private

  sig { params(rb_file: String, i: Integer, absolute_path: String).returns(T.nilable(MochiComponent)) }
  def transpile_component(rb_file, i, absolute_path)
    cls_name = RubyUnderstander.class_name(rb_file)

    print_cmp_start_separator(cls_name, i)
    puts "ClassName:'#{cls_name}'"

    return nil if cls_name.nil? || cls_name.empty?

    methods = RubyUnderstander.extract_method_bodies(rb_file, cls_name)

    amped_ruby_code = rb_file
    if methods.key?("css")
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

      amped_ruby_code = EachMethodGenerator.inject_methods_into_class(
        amped_ruby_code,
        cls_name,
        each_result.each_blocks
      )

      bindings = BindExtractor.extract(each_result.html)
      tag_name = RubyUnderstander.get_cmp_name(rb_file, cls_name)

      if tag_name
        # Build all methods to inject (getters, setters, and internal mounted bridge)
        injected_methods = []
        injected_methods << "def __mochi_mounted(el); @element = el; end"
        injected_methods << "def query(selector); `\#{@element}.shadowRoot.querySelector(\#{selector})`; end"
        injected_methods << "def query_all(selector); `\#{@element}.shadowRoot.querySelectorAll(\#{selector})`; end"

        reactables_arr.each do |var_name|
          if var_name.start_with?("__mochi_attr_cond_") || var_name.start_with?("__mochi_attr_hash_")
            injected_methods << "def get_#{var_name}; #{var_name}(); end"
            injected_methods << "def set_#{var_name}(value); end"
          else
            injected_methods << "def get_#{var_name}; @#{var_name}; end"
            injected_methods << "def set_#{var_name}(value); @#{var_name} = value; `\#{@element}.update_#{var_name}(\#{value})` if @element; end"
          end
        end

        # Cross-component Event Bus APIs
        injected_methods << <<~RUBY
          def emit(event_name, payload = nil)
            `window.Mochi.emit(\#{event_name.to_s}, \#{payload.to_n})`
          end

          def on(event_name, &block)
            @_mochi_subscriptions ||= []
            @_mochi_subscriptions << { event: event_name.to_s, block: block }
            `window.Mochi.on(\#{event_name.to_s}, \#{block})`
          end

          def _cleanup_mochi_subscriptions
            return unless @_mochi_subscriptions
            @_mochi_subscriptions.each do |sub|
              `window.Mochi.off(\#{sub[:event]}, \#{sub[:block]})`
            end
            @_mochi_subscriptions = nil
          end

          def on_window(event, &block)
            handler = `function(e) { \#{block}.$call(e) }`
            `window.addEventListener(\#{event}, \#{handler})`
            @__dom_listeners ||= []
            @__dom_listeners << [`window`, event, handler]
          end

          def on_document(event, &block)
            handler = `function(e) { \#{block}.$call(e) }`
            `document.addEventListener(\#{event}, \#{handler})`
            @__dom_listeners ||= []
            @__dom_listeners << [`document`, event, handler]
          end

          def _cleanup_dom_listeners
            return unless @__dom_listeners
            @__dom_listeners.each do |target, event, handler|
              `\#{target}.removeEventListener(\#{event}, \#{handler})`
            end
            @__dom_listeners = nil
          end
        RUBY

        # Find insertion point once and insert all methods together
        insertion_point = find_second_last_index(amped_ruby_code, "end")
        if insertion_point && insertion_point > 0
          insertion_point += 3
          methods_code = "\n\n  #{injected_methods.join("\n\n  ")}\n"
          amped_ruby_code = amped_ruby_code[0...insertion_point] + methods_code + amped_ruby_code[insertion_point..-1]
        else
          amped_ruby_code += "\n\n#{injected_methods.join("\n\n")}\n"
        end

        web_component = ComponentGenerator.new.generate(
          mochi_cmp_name = cls_name,
          tag_name = tag_name,
          css,
          html = each_result.html,
          reactables,
          bindings.bindings,
          conditional_result.conditionals,
          each_result.each_blocks
        )

        print_cmp_end_seperator(cls_name, i)

        return MochiComponent.new(
          absolute_path: absolute_path,
          name: cls_name,
          imports: imports,
          ruby_code: amped_ruby_code,
          web_component: web_component,
          html: html,
          css: css
        )
      end
    else
      puts "Skipping '#{cls_name}', no css method"
    end

    print_cmp_end_seperator(cls_name, i)
    nil
  end

  sig { params(text: String, substring_to_find: String).returns(T.nilable(Integer)) }
  def find_second_last_index(text, substring_to_find)
    last_idx = text.rindex(substring_to_find)

    return nil unless last_idx && last_idx > 0

    text.rindex(substring_to_find, last_idx - 1)
  end

  sig { params(tag_name: String, i: Integer).void }
  def print_cmp_start_separator(tag_name, i)
    puts "==============================  (#{i})  START   #{tag_name}   =================================="
  end

  sig { params(tag_name: String, i: Integer).void }
  def print_cmp_end_seperator(tag_name, i)
    puts "==============================  (#{i})   END   #{tag_name}   ===================================="
  end
end
