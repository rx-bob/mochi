require "json"
require "lexbor"
require "./binding_manifest"
require "../html/conditional_processor"
require "../html/each_processor"
require "../html/each_row_compiler"
require "../html/event_argument_extractor"
require "../html/html_attributes"
require "../html/dom_attributes"
require "../html/template_expression"
require "../ruby/event_action_generator"

class ComponentGenerator
  CONTROL_TEMPLATE_PREFIXES = ["if ", "unless ", "elsif ", "each "]
  CONTROL_TEMPLATE_KEYWORDS = ["else", "end"]
  ESCAPED_LBRACE            = "\uE000"
  ESCAPED_RBRACE            = "\uE001"

  @each_blocks : Array(EachBlock) = [] of EachBlock
  @each_row_templates : Array(EachRowTemplate) = [] of EachRowTemplate
  @conditionals : Array(ConditionalBlock) = [] of ConditionalBlock
  @next_binding_id : Int32 = 0
  @next_each_id : Int32 = 0
  @next_action_id : Int32 = 0
  @mochi_cmp_name : String = ""
  @ref_names : Array(String) = [] of String
  @expression_parser : TemplateExpressionParser

  # Includes top-level and branch-discovered each blocks so callers can inject
  # every generated each helper method after generation.
  getter each_blocks

  # Root row templates for every compiled list binding. Nested rows live under
  # each root's `children`; callers generate one Ruby row getter per root.
  getter each_row_templates

  def initialize
    @expression_parser = TemplateExpressionParser.new
  end

  def self.escape_double_braces(html : String) : String
    TemplateExpressionParser.escape_literal_braces(html)
  end

  def self.unescape_double_braces(html : String) : String
    html.gsub(ESCAPED_LBRACE, "{").gsub(ESCAPED_RBRACE, "}")
  end

  def generate(
    mochi_cmp_name : String,
    tag_name : String,
    css : String,
    html : String,
    _reactables : String = "[]",
    _bindings : Hash(String, String) = {} of String => String,
    conditionals : Array(ConditionalBlock) = [] of ConditionalBlock,
    each_blocks : Array(EachBlock) = [] of EachBlock,
    method_names : Array(String) = [] of String,
    source_locator : TemplateSourceLocator? = nil,
    props : Array(PropDescriptor) = [] of PropDescriptor,
    emits : Array(ComponentEventDescriptor) = [] of ComponentEventDescriptor,
    expression_parser : TemplateExpressionParser? = nil,
  ) : ComponentManifest
    @mochi_cmp_name = mochi_cmp_name
    @conditionals = conditionals
    @each_blocks = each_blocks
    @each_row_templates.clear
    @next_binding_id = 0
    @next_action_id = 0
    @next_each_id = each_blocks.empty? ? 0 : each_blocks.max_of(&.id) + 1
    @ref_names.clear
    @expression_parser = expression_parser || TemplateExpressionParser.new(source_locator)

    validate_conditional_expressions(conditionals)
    validate_each_expressions(each_blocks)

    escaped_html = self.class.escape_double_braces(html)
    bindings = [] of BindingDescriptor
    events = [] of EventDescriptor
    html_template = walk_html(escaped_html, bindings, events)
    chi_file = "#{tag_name}.chi"

    validate_template_placeholders(mochi_cmp_name, html_template)
    html_template = self.class.unescape_double_braces(html_template)

    manifest = ComponentManifest.new(
      tag_name,
      mochi_cmp_name,
      chi_file,
      html_template,
      css,
      bindings,
      events,
      props: props,
      emits: emits
    )

    validate_event_handlers(mochi_cmp_name, manifest.all_events, method_names)
    manifest
  end

  private def walk_html(html : String, bindings : Array(BindingDescriptor), events : Array(EventDescriptor),
                        context : EachRowDomContext = EachRowDomContext.new) : String
    html = @expression_parser.html_safe(html)
    # Lexbor's document parser drops comments at the body boundary. Mochi uses
    # comment anchors as binding targets, so preserve those markers as inert
    # elements while traversing and restore their exact comment markup after.
    visible_anchors = anchor_comments_in_tree(html, context)
    source = html.gsub(/<!--(if-anchor-\d+|each-anchor-\d+)-->/) do |original, match|
      anchor = match[1]
      next original if visible_anchors.includes?(anchor)
      "<mochi-template-#{anchor}></mochi-template-#{anchor}>"
    end
    body = EachRowCompiler.fragment_root(source, context)

    if body
      body.children.each_with_index do |child, index|
        walk(child, [index], bindings, events, context)
      end
    end

    return "" unless body

    body.inner_html.gsub(/<mochi-template-(if-anchor-\d+|each-anchor-\d+)><\/mochi-template-\1>/) do |_, match|
      "<!--#{match[1]}-->"
    end
  end

  private def anchor_comments_in_tree(html : String, context : EachRowDomContext) : Array(String)
    visible = [] of String
    body = EachRowCompiler.fragment_root(html, context)
    return visible unless body
    collect_anchor_comments(body, visible)
    visible
  end

  private def collect_anchor_comments(node : Lexbor::Node, visible : Array(String))
    if node.tag_name == "_em_comment"
      if match = node.tag_text.match(/\A(if-anchor-\d+|each-anchor-\d+)\z/)
        visible << match[1]
      end
    end
    node.children.each { |child| collect_anchor_comments(child, visible) }
  end

  def rewrite_ruby(
    ruby_code : String,
    class_name : String,
    manifest : ComponentManifest,
    methods : Hash(String, RubyDef),
  ) : String
    removed = ["html", "css"].compact_map { |name| methods[name]? }
    rewritten = RubyBindingRewriter.rewrite(ruby_code, class_name, manifest.bindings, removed)
    actions = manifest.all_events.select { |event| !event.actions.empty? && !event.method_sym.starts_with?("__mochi_each_") }
    return rewritten if actions.empty?
    arities = EventActionGenerator.required_arguments(methods)
    generated = actions.map do |event|
      "\n  def #{event.method_sym}(__event)\n#{EventActionGenerator.statements(event.actions, arities, "    ")}\n  end\n"
    end.join
    insertion = InjectUtils.find_insertion_point(rewritten, class_name, "end", 1)
    insertion ? InjectUtils.insert_code(rewritten, insertion, generated) : rewritten
  end

  private def walk(
    node : Lexbor::Node,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
    parent_context : EachRowDomContext,
  )
    tag = node.tag_name

    if tag == "_text"
      collect_text_bindings(node.tag_text, path, bindings)
      return
    end

    if tag == "_em_comment"
      collect_anchor_binding(node.tag_text, path, bindings, events, parent_context)
      return
    end

    if match = tag.match(/^mochi-template-(if-anchor-\d+|each-anchor-\d+)$/)
      collect_anchor_binding(match[1], path, bindings, events, parent_context)
      return
    end

    first_binding = bindings.size
    collect_attribute_bindings(node, path, bindings, events)

    # Browsers parse SVG geometry even in detached templates. Keep authored
    # placeholders inert until the complete attribute value is available.
    if tag.downcase == "svg" || parent_context.namespace == "svg"
      attrs = DomAttributes.read(node)
      bindings[first_binding..].select { |binding| binding.kind == "attr" }
        .compact_map(&.attr_name).uniq.each do |name|
        if value = attrs[name]?
          node.attribute_remove(name)
          node.attribute_add("data-mochi-svg-#{name.downcase}", value)
        end
      end
    end

    node.children.each_with_index do |child, index|
      lowered_tag = tag.downcase
      child_namespace = if lowered_tag == "svg"
                          "svg"
                        elsif lowered_tag == "foreignobject"
                          "html"
                        else
                          parent_context.namespace
                        end
      walk(child, path + [index], bindings, events, EachRowDomContext.new(tag, child_namespace))
    end
  end

  private def collect_text_bindings(text : String, path : Array(Int32), bindings : Array(BindingDescriptor))
    expressions = @expression_parser.scan(text, "text")
    trusted_sources = {} of Int32 => String
    expressions.each_with_index do |expression, index|
      if source = TemplateExpressionParser.trusted_markup_source(expression.source)
        trusted_sources[index] = source
      end
    end
    has_trusted = !trusted_sources.empty?

    expressions.each_with_index do |expression, index|
      before = text.byte_slice(0, expression.template_start).strip
      after = text.byte_slice(expression.template_end, text.bytesize - expression.template_end).strip
      standalone = before.empty? && after.empty?
      trusted_source = trusted_sources[index]?
      kind = if standalone && trusted_source
               "html"
             elsif has_trusted
               "text_html"
             else
               "text"
             end
      bindings << new_expression_binding(
        path,
        kind,
        nil,
        text,
        expression,
        trusted_markup: !trusted_source.nil?,
        expression_override: trusted_source
      )
    end
  end

  private def collect_anchor_binding(
    text : String,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
    dom_context : EachRowDomContext,
  )
    if match = text.match(/if-anchor-(\d+)/)
      id = match[1].to_i
      block = @conditionals.find { |candidate| candidate.id == id }
      return unless block

      binding_id = allocate_binding_id
      branches = block.branches.map { |branch| process_branch(branch, dom_context) }
      template_text = branches.first?.try(&.html_template) || block.content

      bindings << BindingDescriptor.new(
        binding_id,
        path.dup,
        "cond",
        "__mochi_bind_#{binding_id}",
        nil,
        template_text,
        "__mochi_cond_#{block.id}",
        branches,
        span: @expression_parser.locator.try(&.locate(block.condition))
      )
    elsif match = text.match(/each-anchor-(\d+)/)
      id = match[1].to_i
      block = @each_blocks.find { |candidate| candidate.id == id }
      return unless block

      ids = EachRowIds.new(@next_each_id)
      row = EachRowCompiler.compile(block, @expression_parser, dom_context, ids)
      @next_each_id = ids.next_id
      @each_row_templates << row
      row.all_events.each do |event|
        events << EventDescriptor.new(
          path,
          event.event,
          event.actions.empty? ? event.handler : event.wrapper_sym,
          event.args,
          component: event.component,
          modifiers: event.modifiers,
          actions: event.actions
        )
      end

      loop_meta = if idx = block.loop_def.index_name
                    "#{block.loop_def.item_name},#{idx}"
                  else
                    block.loop_def.item_name
                  end
      bindings << new_each_binding(path, loop_meta, row)
    end
  end

  private def new_each_binding(
    path : Array(Int32),
    attr_name : String,
    row : EachRowTemplate,
  ) : BindingDescriptor
    id = allocate_binding_id
    getter_sym = "__mochi_each_#{row.block_id}_rows"
    BindingDescriptor.new(
      id,
      path.dup,
      "each",
      getter_sym,
      attr_name,
      row.template,
      getter_sym,
      [] of ConditionalBranchDescriptor,
      nil,
      nil,
      nil,
      [] of String,
      nil,
      row
    )
  end

  private def collect_attribute_bindings(
    node : Lexbor::Node,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
  )
    return unless node.attributes

    attrs = DomAttributes.read(node)
    additions = [] of Tuple(String, String)
    removals = [] of String
    bound_events = attrs.keys.select { |name| name == "bind:value" || name == "bind:checked" }
      .map { |name| BoundProperty.event(name[5..], node.tag_name) }

    attrs.each do |name, value|
      if name.starts_with?("bind:")
        attr_name = name[5..]
        normalized_value = if value.strip.matches?(/\A@[a-zA-Z_][a-zA-Z0-9_]*\z/)
                             "{#{value.strip}}"
                           else
                             value
                           end
        additions << {attr_name, normalized_value}
        removals << name
        if attr_name == "value" || attr_name == "checked"
          add_two_way_binding(path, attr_name, normalized_value, bindings, events, additions, node.tag_name)
        else
          add_attribute_binding(path, attr_name, normalized_value, bindings)
        end
      elsif name == "ref"
        add_named_ref(value, name, additions, removals)
      elsif name.starts_with?("data-mochi-")
        next
      elsif name.starts_with?("on:")
        call = event_call(name, value)
        event_name = call.event
        next if event_name.empty?

        if expression = @expression_parser.scan(value, "event").first?
          method_name = expression.source.split("(").first.strip
          additions << {"data-mochi-#{event_name}", method_name}
          additions << {"data-mochi-modifiers-#{event_name}", call.modifiers.join(",")} unless call.modifiers.empty?
          removals << name
          args = event_args(attrs, event_name)
          events << EventDescriptor.new(
            path,
            event_name,
            method_name,
            args,
            component: true,
            modifiers: call.modifiers
          )
          args.each { |arg| add_event_expression_binding(path, arg, bindings) }
        end
      elsif name.starts_with?("on")
        call = event_call(name, value)
        event_name = call.event
        next if event_name.empty?

        if expression = @expression_parser.scan(value, "event").first?
          method_name = expression.source.split("(").first.strip
          additions << {"data-mochi-#{event_name}", method_name}
          additions << {"data-mochi-modifiers-#{event_name}", call.modifiers.join(",")} unless call.modifiers.empty?
          removals << name
          args = event_args(attrs, event_name)
          events << EventDescriptor.new(path, event_name, method_name, args, modifiers: call.modifiers)
          args.each { |arg| add_event_expression_binding(path, arg, bindings) } unless bound_events.includes?(event_name)
        end
      elsif value.includes?("{")
        add_attribute_binding(path, name, value, bindings)
      end
    end

    compose_bound_events(path, bindings, events, additions, removals)
    removals.each { |name| node.attribute_remove(name) }
    additions.each { |name, value| node.attribute_add(name, value) }
  end

  private def add_named_ref(
    value : String,
    attribute : String,
    additions : Array(Tuple(String, String)),
    removals : Array(String),
  )
    ref_name = value.strip
    if ref_name.empty? || ref_name.includes?("{")
      raise TemplateExpressionError.new("ref must be a static name, got #{value.inspect}")
    end
    unless ref_name.matches?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
      raise TemplateExpressionError.new(
        "ref name must start with a letter or underscore and contain only letters, digits, and underscores, got #{ref_name.inspect}"
      )
    end
    if @ref_names.includes?(ref_name)
      raise TemplateExpressionError.new("duplicate ref #{ref_name.inspect} in one component")
    end
    @ref_names << ref_name
    additions << {"data-mochi-ref", ref_name}
    removals << attribute
  end

  private def event_call(raw_name : String, value : String) : EventCall
    call = EventCall.new(raw_name, "", [] of String)
    unknown = call.modifiers.reject { |modifier| EventCall::MODIFIERS.includes?(modifier) }
    span = @expression_parser.scan(value, "event").first?.try(&.span)
    unless unknown.empty?
      raise TemplateExpressionError.new(
        "unknown event modifier #{unknown.first.inspect} on #{raw_name.inspect}; " \
        "expected #{EventCall::MODIFIERS.join(", ")}",
        span
      )
    end
    if call.modifiers.uniq.size != call.modifiers.size
      raise TemplateExpressionError.new("duplicate event modifier on #{raw_name.inspect}", span)
    end
    call
  end

  private def add_attribute_binding(
    path : Array(Int32),
    attr_name : String,
    value : String,
    bindings : Array(BindingDescriptor),
  )
    @expression_parser.scan(value, "attribute").each do |expression|
      if TemplateExpressionParser.trusted_markup_source(expression.source)
        raise TemplateExpressionError.new(
          "Mochi.raw is only supported in text content, not in the #{attr_name} attribute",
          expression.span
        )
      end
      bindings << new_expression_binding(path, "attr", attr_name, value, expression)
    end
  end

  # `bind:value` and `bind:checked` are two-way: the getter feeds the DOM
  # property, while a generated setter receives the normalized event payload
  # and writes the incoming value back into the instance variable.
  private def add_two_way_binding(
    path : Array(Int32),
    attr_name : String,
    value : String,
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
    additions : Array(Tuple(String, String)),
    tag : String,
  )
    expression = BoundProperty.expression(value, attr_name, @expression_parser)

    setter_sym = "__mochi_set_#{expression.source[1..].gsub(/[^a-zA-Z0-9_]/, "_")}"
    event_name = BoundProperty.event(attr_name, tag)
    bindings << new_expression_binding(path, "prop", attr_name, value, expression, setter_sym: setter_sym)
    events << EventDescriptor.new(path, event_name, setter_sym)
    additions << {"data-mochi-#{event_name}", setter_sym}
  end

  private def compose_bound_events(path, bindings, events, additions, removals)
    properties = bindings.select { |binding| binding.path == path && binding.setter_sym }
    setters = properties.map(&.setter_sym)
    local = events.select { |event| event.path == path && !event.component }
    local.group_by(&.event).each do |name, group|
      writes = group.select { |event| setters.includes?(event.method_sym) }
      calls = group.reject { |event| setters.includes?(event.method_sym) }
      next if writes.empty? || calls.empty?
      actions = writes.map do |event|
        binding = properties.find! { |property| property.setter_sym == event.method_sym }
        EventAction.new("set", binding.getter_expr.not_nil!, binding.attr_name, span: binding.span)
      end
      calls.each { |event| actions << EventAction.new("call", event.method_sym, args: event.args) }
      method = "__mochi_action_#{@next_action_id}"
      @next_action_id += 1
      events.reject! { |event| group.includes?(event) }
      modifiers = calls.flat_map(&.modifiers).uniq
      events << EventDescriptor.new(path, name, method, modifiers: modifiers, actions: actions)
      additions << {"data-mochi-#{name}", method}
      removals << "data-mochi-args-#{name}"
    end
  end

  # Event expressions such as `@query` need their value available to the
  # loader. Registering a hidden binding makes the VM evaluate the expression
  # and cache the result alongside the element's other binding values.
  private def add_event_expression_binding(
    path : Array(Int32),
    argument : EventArgumentDescriptor,
    bindings : Array(BindingDescriptor),
  )
    return unless argument.kind == "expr"
    expression = argument.value.try(&.strip)
    return if expression.nil? || expression.empty?
    # Only expr bindings publish the expression identity used by event
    # dispatch. A text/attribute binding with the same Ruby is not a substitute.
    # Keep deduplication local to this branch's binding list.
    return if bindings.any? { |binding| binding.getter_expr == expression && binding.kind == "expr" }
    bindings << new_binding(path, "expr", nil, expression, expression)
  end

  # Build one conditional branch fragment and recursively compile any nested
  # conditionals or each blocks it contains. Paths and binding IDs are relative
  # to the branch fragment; IDs themselves are component-global.
  private def process_branch(branch : ConditionalBranch, context : EachRowDomContext) : ConditionalBranchDescriptor
    html = self.class.escape_double_braces(branch_with_anchors(branch))
    each_result = EachProcessor.process(html, @next_each_id)
    span = @expression_parser.locator.try(&.locate(branch.condition || branch.content))
    EachRowCompiler.validate_context_nesting(each_result.html, context, span, @expression_parser)

    unless each_result.each_blocks.empty?
      @each_blocks.concat(each_result.each_blocks)
      @next_each_id += each_result.each_blocks.size
    end

    branch_bindings = [] of BindingDescriptor
    branch_events = [] of EventDescriptor
    template = walk_html(each_result.html, branch_bindings, branch_events, context)
    validate_template_placeholders(@mochi_cmp_name, template)
    template = self.class.unescape_double_braces(template)
    ConditionalBranchDescriptor.new(template, branch_bindings, branch_events, context.tag, context.namespace, span)
  end

  private def branch_with_anchors(branch : ConditionalBranch) : String
    html = branch.content

    branch.children.sort_by { |child| -child.start_pos }.each do |child|
      rel_start = child.start_pos - branch.start_pos
      rel_end = child.end_pos - branch.start_pos
      next if rel_start < 0 || rel_end > html.size || rel_start > rel_end

      html = html[0...rel_start] + "<!--if-anchor-#{child.id}-->" + html[rel_end..-1]
    end

    html
  end

  private def allocate_binding_id : Int32
    id = @next_binding_id
    @next_binding_id += 1
    id
  end

  private def event_args(attrs : Hash(String, String), event_name : String) : Array(EventArgumentDescriptor)
    if raw = attrs["data-mochi-args-#{event_name}"]?
      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map { |item| EventArgumentDescriptor.from_json_object(item) }
      rescue ex
        raise "invalid event arguments for on#{event_name}: #{ex.message}"
      end
    end

    args = [] of EventArgumentDescriptor
    index = 0

    while attrs.has_key?("data-mochi-arg-#{index}")
      raw = attrs["data-mochi-arg-#{index}"].strip
      if raw.starts_with?("{") && raw.ends_with?("}")
        raw = raw[1...-1]
      end
      args << EventArgumentDescriptor.parse(raw)
      index += 1
    end

    args
  end

  private def new_expression_binding(
    path : Array(Int32),
    kind : String,
    attr_name : String?,
    template_text : String,
    expression : TemplateExpression,
    branches : Array(ConditionalBranchDescriptor) = [] of ConditionalBranchDescriptor,
    setter_sym : String? = nil,
    trusted_markup : Bool = false,
    expression_override : String? = nil,
  ) : BindingDescriptor
    id = allocate_binding_id
    BindingDescriptor.new(
      id,
      path.dup,
      kind,
      "__mochi_bind_#{id}",
      attr_name,
      template_text,
      normalize_expression(expression_override || expression.source),
      branches,
      setter_sym,
      expression.template_start,
      expression.template_end,
      expression.scope,
      expression.span,
      trusted_markup: trusted_markup,
      attr_kind: kind == "attr" && attr_name ? HtmlAttributes.kind(attr_name) : nil
    )
  end

  private def new_binding(
    path : Array(Int32),
    kind : String,
    attr_name : String?,
    template_text : String,
    expression : String,
    branches : Array(ConditionalBranchDescriptor) = [] of ConditionalBranchDescriptor,
    setter_sym : String? = nil,
  ) : BindingDescriptor
    id = allocate_binding_id
    BindingDescriptor.new(
      id,
      path.dup,
      kind,
      "__mochi_bind_#{id}",
      attr_name,
      template_text,
      normalize_expression(expression),
      branches,
      setter_sym
    )
  end

  # Strict binding syntax: `{@foo}` reads the instance variable `@foo`,
  # while `{foo}` calls the component method `foo`. Never rewrite one into
  # the other here; validation in Compiler#transpile_component catches
  # method bindings that do not resolve to a component method.
  private def normalize_expression(expression : String) : String
    expression.strip
  end

  private def validate_event_handlers(
    class_name : String,
    events : Array(EventDescriptor),
    method_names : Array(String),
  )
    return if method_names.empty?

    events.each do |event|
      names = event.actions.empty? ? [event.method_sym] : event.actions.select { |action| action.kind == "call" }.map(&.target)
      names.each do |name|
        next if name.starts_with?("__mochi_") || method_names.includes?(name)
        raise "Component '#{class_name}' has an undefined event handler: on#{event.event}=\"{#{name}}\""
      end
    end
  end

  # Event argument descriptors are JSON in a data attribute. Their braces are
  # data, not template syntax, so blank the value before scanning the DOM.
  private def scannable_template(template : String) : String
    template.gsub(/data-mochi-args-([a-zA-Z0-9_-]+)=(["'])(.*?)\2/m) do |_, match|
      %(data-mochi-args-#{match[1]}="")
    end
  end

  private def validate_template_placeholders(class_name : String, template : String)
    @expression_parser.scan(HTML.unescape(scannable_template(template)), "template", validate: false).each do |expression|
      inner = expression.source
      if CONTROL_TEMPLATE_KEYWORDS.includes?(inner) || CONTROL_TEMPLATE_PREFIXES.any? { |prefix| inner.starts_with?(prefix) }
        raise TemplateExpressionError.new(
          "Component '#{class_name}' contains an uncompiled template block '{#{inner}}'",
          expression.span
        )
      end
      @expression_parser.validate!(expression)
    end
  end

  private def validate_conditional_expressions(conditionals : Array(ConditionalBlock))
    conditionals.each do |block|
      block.branches.each do |branch|
        if condition = branch.condition
          @expression_parser.validate_source!(condition, "condition")
        end
      end
    end
  end

  private def validate_each_expressions(each_blocks : Array(EachBlock))
    each_blocks.each do |block|
      @expression_parser.validate_source!(block.loop_def.array_name, "each")
    end
  end
end
