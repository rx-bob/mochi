require "digest/sha1"
require "../../../../fragments/vendor/libpftrace/bindings/crystal/src/pftrace"
require "./trace_helper"
require "../../webcomponents/component_generator"
require "../../gvm/mrbc_compiler"
require "../../tree-sitter/instance_var_analyzer"
require "../../tree-sitter/source_slicer"
require "../../ruby/ruby_understander"
require "../../html/attribute_conditional_extractor"
require "../../html/attribute_hash_extractor"
require "../../html/event_argument_extractor"
require "../../html/conditional_processor"
require "../../html/each_processor"
require "../../html/template_expression"
require "../../ruby/attribute_method_generator"
require "../../ruby/attribute_hash_generator"
require "../../ruby/conditional_method_generator"
require "../../ruby/each_method_generator"

record TranspileFileResult, components : Array(MochiComponent), helper : HelperUnit?

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
    helpers = [] of HelperUnit
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
          result = transpile_file(rb_file, absolute_path, i)

          i += 1
          if result.components.empty?
            prelude_files << {absolute_path, rb_file} unless rb_file.strip.empty?
          else
            components.concat(result.components)
            helpers << result.helper.not_nil! if result.helper
          end
        rescue ex
          errors << "Error processing file #{path}: #{ex.message}"
        end
      end
    end

    unless errors.empty?
      raise "Component transpilation failed:\n#{errors.join("\n")}"
    end

    validate_component_inventory(components)

    puts "Done with preparing components for transpilation (#{Time.monotonic})"
    prelude_code = prelude_files.sort_by(&.[0]).map(&.[1]).join("\n\n")

    trace_slice(trace, "EmitBytecode", sequence_id) do
      compiler = MrbcCompiler.new
      compiler.compile(components, output_dir, prelude_code, helpers)
      compiler.warnings.each { |warning| STDERR.puts "Warning: #{warning}" }
      puts "Wrote #{compiler.chi_paths.size} component(s) and #{compiler.manifest_path}"
    end

    puts "Transpilation finished"
  end

  def transpile_component(rb_file : String, i : Int32, absolute_path : String)
    transpile_file(rb_file, absolute_path, i).components.first?
  end

  # Discovers every component in one Ruby file. A file can hold a screen, its
  # row component, and helpers; each component owns only its own class body.
  def transpile_file(rb_file : String, absolute_path : String, i : Int32 = 1) : TranspileFileResult
    tree = @ruby_parser.parse(rb_file)
    root = tree.root_node

    declarations = TreeSitter::ClassExtractor.extract_class_decls(root)
    class_declarations = declarations.select(&.class?)
    component_decls = discover_component_declarations(class_declarations, absolute_path)
    return TranspileFileResult.new([] of MochiComponent, nil) if component_decls.empty?

    validate_component_declarations(component_decls, class_declarations, absolute_path)

    legacy_source = legacy_single_source?(component_decls, class_declarations)
    helper = nil
    unless legacy_source
      helper_source = TreeSitter::SourceSlicer.remove_ranges(
        rb_file,
        component_decls.map(&.range)
      )
      helper = build_helper(helper_source, absolute_path)
    end

    components = component_decls.map do |declaration|
      source = legacy_source ? rb_file : component_source_for(
        rb_file,
        declaration,
        declarations
      )
      transpile_class(
        declaration,
        source,
        helper.try(&.key),
        root,
        rb_file,
        absolute_path,
        i
      )
    end

    TranspileFileResult.new(components, helper)
  end

  private def discover_component_declarations(
    class_declarations : Array(TreeSitter::ClassDecl),
    absolute_path : String,
  ) : Array(TreeSitter::ClassDecl)
    tagged = class_declarations.select(&.component?)
    if tagged.empty?
      html_component = class_declarations.find(&.has_html)
      return [] of TreeSitter::ClassDecl unless html_component

      raise "Component '#{html_component.name}' defines an html method but no @tag_name at #{html_component.location(absolute_path)}"
    end

    tagged.each do |declaration|
      tag_name = declaration.tag_name.not_nil!
      unless tag_name.includes?("-")
        raise "Component '#{declaration.name}' has invalid @tag_name '#{tag_name}' at #{declaration.location(absolute_path)}: custom element tag names must contain a hyphen"
      end

      unless declaration.has_html
        raise "Component '#{declaration.name}' defines @tag_name but no html method at #{declaration.location(absolute_path)}"
      end
    end

    tagged
  end

  private def legacy_single_source?(
    components : Array(TreeSitter::ClassDecl),
    class_declarations : Array(TreeSitter::ClassDecl),
  ) : Bool
    return false unless components.size == 1

    component = components.first
    class_declarations.none? do |declaration|
      next false if same_declaration?(declaration, component)
      next false if range_contains?(component, declaration)

      true
    end
  end

  private def validate_component_declarations(
    components : Array(TreeSitter::ClassDecl),
    class_declarations : Array(TreeSitter::ClassDecl),
    absolute_path : String,
  ) : Nil
    grouped = class_declarations.group_by(&.qualified_name)
    components.each do |component|
      declarations = grouped[component.qualified_name]
      next if declarations.size <= 1

      locations = declarations.map(&.location(absolute_path)).join(", ")
      raise "Component class '#{component.qualified_name}' is reopened at #{locations}; keep a component class in one declaration"
    end

    components.each do |component|
      if outer = components.find { |candidate| range_contains?(candidate, component) }
        raise "Component '#{component.name}' is nested inside component '#{outer.name}' at #{component.location(absolute_path)}"
      end
    end

    tags = {} of String => TreeSitter::ClassDecl
    components.each do |component|
      tag = component.tag_name.not_nil!
      if previous = tags[tag]?
        raise "Duplicate component tag '#{tag}' at #{previous.location(absolute_path)} and #{component.location(absolute_path)}"
      end
      tags[tag] = component
    end

    class_names = {} of String => TreeSitter::ClassDecl
    components.each do |component|
      if previous = class_names[component.simple_name]?
        raise "Duplicate component class '#{component.simple_name}' at #{previous.location(absolute_path)} and #{component.location(absolute_path)}"
      end
      class_names[component.simple_name] = component
    end
  end

  private def validate_component_inventory(components : Array(MochiComponent)) : Nil
    tags = {} of String => MochiComponent
    class_names = {} of String => MochiComponent

    components.each do |component|
      tag = component.manifest.tag_name
      if previous = tags[tag]?
        raise "Duplicate component tag '#{tag}' at #{component_location(previous)} and #{component_location(component)}"
      end
      tags[tag] = component

      class_name = component.manifest.class_name
      if previous = class_names[class_name]?
        raise "Duplicate component class '#{class_name}' at #{component_location(previous)} and #{component_location(component)}"
      end
      class_names[class_name] = component
    end
  end

  private def component_location(component : MochiComponent) : String
    return component.absolute_path if component.class_line <= 0

    "#{component.absolute_path}:#{component.class_line}"
  end

  private def component_source_for(
    source : String,
    component : TreeSitter::ClassDecl,
    declarations : Array(TreeSitter::ClassDecl),
  ) : String
    start_byte = component.wrapper_start_byte
    end_byte = component.wrapper_end_byte
    if start_byte == component.start_byte && end_byte == component.end_byte
      return source.byte_slice(component.start_byte, component.end_byte - component.start_byte)
    end

    removals = [] of Tuple(Int32, Int32)

    declarations.each do |declaration|
      next if same_declaration?(declaration, component)
      next if declaration.start_byte < start_byte || declaration.end_byte > end_byte
      next if range_contains?(component, declaration)
      next if range_contains?(declaration, component)

      removals << declaration.range
    end

    TreeSitter::SourceSlicer.remove_ranges(source, removals)
  end

  private def build_helper(source : String, absolute_path : String) : HelperUnit?
    return nil if source.strip.empty?

    digest = Digest::SHA1.hexdigest(absolute_path)[0, 12]
    HelperUnit.new("mochi-helpers-#{digest}.chi", source, absolute_path)
  end

  private def same_declaration?(left : TreeSitter::ClassDecl, right : TreeSitter::ClassDecl) : Bool
    left.start_byte == right.start_byte && left.end_byte == right.end_byte
  end

  private def range_contains?(outer : TreeSitter::ClassDecl, inner : TreeSitter::ClassDecl) : Bool
    return false if same_declaration?(inner, outer)

    inner.start_byte >= outer.start_byte && inner.end_byte <= outer.end_byte
  end

  private def transpile_class(
    declaration : TreeSitter::ClassDecl,
    component_source : String,
    helper_chi : String?,
    root : TreeSitter::Node,
    rb_file : String,
    absolute_path : String,
    i : Int32,
  ) : MochiComponent
    cls_name = declaration.name
    print_cmp_start_separator(cls_name, i)
    puts "ClassName:'#{cls_name}'"

    methods : Hash(String, RubyDef) = TreeSitter::MethodBodyExtractor.extract_method_bodies_from_class(
      declaration.node,
      cls_name,
      rb_file
    )
    tag_name = declaration.tag_name.not_nil!
    html_method = methods["html"]?

    if html_method.nil?
      raise "Component '#{cls_name}' defines @tag_name but no html method at #{declaration.location(absolute_path)}"
    end

    imports = RubyUnderstander.get_imports(root)
    css = if css_method = methods["css"]?
            css_method.raw_string || RubyUnderstander.extract_raw_string_from_def_body(css_method.body, "css")
          else
            ""
          end
    html = html_method.raw_string || RubyUnderstander.extract_raw_string_from_def_body(html_method.body, "html")
    source_locator = TemplateSourceLocator.new(
      rb_file,
      absolute_path,
      html_method.raw_string_start || 0,
      html_method.raw_string_end || rb_file.bytesize
    )

    # Remove html and css before injecting helpers. Their string bodies may
    # contain `{end}`, which must never be mistaken for the class terminator.
    amped_ruby_code = RubyUnderstander.remove_methods(component_source, cls_name, ["html", "css"])

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
    html = EventArgumentExtractor.process(html, source_locator)

    # Analyze instance variables to determine reactables automatically
    vars = TreeSitter::InstanceVarAnalyzer.analyze_class(declaration.node)
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
      methods.keys,
      source_locator
    )
    manifest.helper_chi = helper_chi

    validate_binding_methods(cls_name, manifest.all_bindings, methods.keys, declaration.attribute_readers)
    validate_row_expressions(cls_name, generator.each_row_templates, methods.keys, declaration.attribute_readers)

    amped_ruby_code = EachMethodGenerator.inject_methods_into_class(
      amped_ruby_code,
      cls_name,
      generator.each_row_templates
    )

    rewritten_ruby_code = ComponentGenerator.new.rewrite_ruby(
      amped_ruby_code,
      cls_name,
      manifest,
      methods
    )

    print_cmp_end_seperator(cls_name, i)
    MochiComponent.new(
      absolute_path,
      cls_name,
      imports,
      rewritten_ruby_code,
      manifest,
      manifest.html_template,
      css,
      declaration.line
    )
  end

  private def validate_binding_methods(
    cls_name : String,
    bindings : Array(BindingDescriptor),
    method_names : Array(String),
    attribute_readers : Set(String),
  ) : Nil
    readable = Set(String).new
    method_names.each { |name| readable << name }
    attribute_readers.each { |name| readable << name }

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

  # Rejects bare method names in list rows that cannot resolve to a component
  # method, attribute reader, literal, or one of the row's lexical names.
  private def validate_row_expressions(
    cls_name : String,
    rows : Array(EachRowTemplate),
    method_names : Array(String),
    attribute_readers : Set(String),
  ) : Nil
    readable = Set(String).new
    method_names.each { |name| readable << name }
    attribute_readers.each { |name| readable << name }

    rows.each do |root_row|
      root_row.each_template do |row|
        row.bindings.each do |binding|
          validate_row_expression(cls_name, binding.expression, row.scope_names, readable, binding.span)
        end
        row.events.each do |event|
          scope_names = row_scope_names(event.scope)
          event.args.each do |argument|
            next unless argument.kind == "expr"
            validate_row_expression(cls_name, argument.value || "", scope_names, readable, event.span)
          end
        end
      end
    end
  end

  private def validate_row_expression(
    cls_name : String,
    expression : String,
    scope_names : Array(String),
    readable : Set(String),
    span : TemplateSourceSpan?,
  ) : Nil
    source = expression.strip
    while source.starts_with?("!")
      source = source.byte_slice(1, source.bytesize - 1).strip
    end
    return if source.empty?
    return if source.starts_with?("@") || source.starts_with?("!") || source.starts_with?("$")
    return if BINDING_LITERALS.includes?(source)
    return unless match = source.match(/\A([a-z_][a-zA-Z0-9_]*[?!]?)(.*)\z/m)

    name = match[1]
    return if name == "self"
    return if scope_names.includes?(name)
    return if readable.includes?(name)

    location = span ? "#{span}: " : ""
    raise "#{location}Component '#{cls_name}' list row uses undefined name '#{name}' in #{expression.inspect}; use a loop name, @ivar, or component method"
  end

  private def row_scope_names(scope : Array(EachRowScope)) : Array(String)
    names = [] of String
    scope.each do |entry|
      names << entry.item_name unless names.includes?(entry.item_name)
      names << entry.index_name unless names.includes?(entry.index_name)
      names << "index" unless names.includes?("index")
    end
    names
  end

  private def validate_ivar_capacity(cls_name : String, vars : Array(TreeSitter::InstanceVarAnalyzer::VariableInfo)) : Nil
    ivars = vars.map(&.name).reject { |name| name == "@tag_name" }.uniq
    return if ivars.size <= MAX_TRACKED_IVARS

    raise "Component '#{cls_name}' declares #{ivars.size} instance variables, exceeding the GVM limit of #{MAX_TRACKED_IVARS}"
  end
end
