require "json"
require "html"
require "lexbor"
require "./each_processor"
require "./each_row_template"
require "./event_argument_extractor"
require "./html_attributes"
require "./template_expression"
require "./attribute_conditional_extractor"
require "./attribute_hash_extractor"
require "./conditional_processor"

# Compiles one each block into a static row template plus evaluated value
# slots and nested row trees. Expression text stays in the compiler; the
# browser manifest receives only descriptors and the generated Ruby row getter
# evaluates every value inside the VM.
class EachRowCompiler
  SENTINEL_START   = "\u{E002}"
  SENTINEL_END     = "\u{E003}"
  SENTINEL_PATTERN = Regex.new(SENTINEL_START + "([0-9]+)" + SENTINEL_END)
  ARG_MARKER       = /\A__mochi_row_args_(\d+)__(.*)\z/m
  CONTROL_PREFIXES = ["if ", "unless ", "elsif ", "each "]
  CONTROL_KEYWORDS = ["else", "end"]

  def self.sentinel(slot : Int32) : String
    "#{SENTINEL_START}#{slot}#{SENTINEL_END}"
  end

  def self.compile(
    block : EachBlock,
    parser : TemplateExpressionParser,
    context : EachRowDomContext = EachRowDomContext.new,
    ids : EachRowIds = EachRowIds.new(block.id + 1),
  ) : EachRowTemplate
    compile_row(block, parser, [] of EachRowScope, context, ids)
  end

  private def self.compile_row(
    block : EachBlock,
    parser : TemplateExpressionParser,
    parent_scope : Array(EachRowScope),
    context : EachRowDomContext,
    ids : EachRowIds,
  ) : EachRowTemplate
    item_name = block.loop_def.item_name
    declared_index = block.loop_def.index_name
    index_name = declared_index || "index"
    row_span = parser.locator.try(&.locate(block.loop_def.array_name))
    if item_name == index_name
      raise TemplateExpressionError.new(
        "each item and index must have different names, got #{item_name.inspect}",
        row_span
      )
    end
    key_expression = block.loop_def.key_expression
    parser.validate_source!(key_expression, "each key") if key_expression

    entry = EachRowScope.new(item_name, index_name, declared_index)
    scope = parent_scope + [entry]
    fragment = compile_fragment(block.content, block.id, parser, scope, context, ids, row_span)
    EachRowTemplate.new(block.id, block.loop_def.array_name, item_name, index_name,
      declared_index, fragment.template, fragment.bindings, fragment.events,
      fragment.children, scope, key_expression, row_span, fragment.attribute_conditionals,
      fragment.attribute_hashes, context.tag, context.namespace, fragment.conditionals)
  end

  private def self.compile_fragment(
    template : String, fragment_id : Int32, parser : TemplateExpressionParser,
    scope : Array(EachRowScope), context : EachRowDomContext, ids : EachRowIds,
    row_span : TemplateSourceSpan?,
  ) : EachRowFragment
    scope_names = scope_names_for(scope)
    if with_directive = template.match(/\{with(?:\s|})/)
      span = parser.locator.try(&.locate(with_directive[0]))
      raise TemplateExpressionError.new(
        "the {with} directive is not supported; move the lookup into a Ruby helper method and call that method in the template",
        span
      )
    end
    # Attribute helpers belong to this lexical scope. Nested loops are
    # compiled separately and must retain their own attribute expressions.
    protected_loops = {} of String => String
    EachProcessor.roots(EachProcessor.extract_each_blocks(template)).reverse_each do |child|
      marker = "<!--mochi-pending-loop-#{child.id}-->"
      protected_loops[marker] = template[child.start_pos...child.end_pos]
      template = EachProcessor.replace_range(template, child.start_pos, child.end_pos, marker)
    end
    hash_attributes = AttributeHashExtractor.process(template, parser)
    conditional_attributes = AttributeConditionalExtractor.process(hash_attributes.html, parser)
    template = rewrite_row_attribute_helpers(conditional_attributes.html, fragment_id, scope)
    template = TemplateExpressionParser.escape_literal_braces(template)
    protected_loops.each { |marker, source| template = template.gsub(marker, source) }
    conditional_result = ConditionalProcessor.process(template)
    blocks = conditional_result.conditionals.reject do |block|
      conditional_result.conditionals.any? { |other| other != block && other.contains?(block) }
    end.sort_by(&.start_pos)
    conditional_ids = {} of Int32 => Int32
    blocks.each { |block| conditional_ids[block.id] = ids.take }
    template = conditional_result.html.gsub(/<!--if-anchor-(\d+)-->/) do |_, match|
      "<!--mochi-cond-#{conditional_ids[match[1].to_i]}-->"
    end
    each_result = EachProcessor.process(template, ids.next_id)
    ids.next_id += each_result.each_blocks.size
    children_blocks = EachProcessor.roots(each_result.each_blocks)
    template = each_result.html.gsub("<!--each-anchor-", "<!--mochi-each-")
    child_contexts = contexts_for_children(template, children_blocks, context, parser)
    validate_context_nesting(template, context, row_span, parser)
    if TemplateAttributes.scan(template, parser).any? { |attribute| attribute.name.downcase == "ref" }
      raise TemplateExpressionError.new(
        "ref is not supported inside each rows; place named refs in the static component template",
        row_span
      )
    end
    template, preprocessed_args = extract_event_arguments(template, parser)
    event_index = 0
    row_events = [] of EachRowEventDescriptor

    template, _calls = EventArgumentExtractor.rewrite(template, parser.locator, parser) do |call|
      handler = call.method_name
      arguments = [] of EventArgumentDescriptor
      if marker = handler.match(ARG_MARKER)
        handler = marker[2]
        arguments = preprocessed_args[marker[1].to_i]? || [] of EventArgumentDescriptor
      elsif !call.arguments.empty?
        arguments = call.arguments.map { |argument| EventArgumentDescriptor.parse(argument) }
      end

      unless arguments.empty?
        if arguments.any? { |argument| argument.kind == "element" }
          raise TemplateExpressionError.new(
            "DOM elements cannot be passed to Ruby event handlers; use $event",
            call.span
          )
        end

        event_index += 1
        wrapper = "__mochi_each_#{fragment_id}_ev_#{event_index}"
        row_events << EachRowEventDescriptor.new(
          call.event,
          handler,
          wrapper,
          arguments,
          scope.dup,
          call.span,
          call.component?,
          call.modifiers
        )
        %(data-mochi-#{call.event}="#{wrapper}"#{EventArgumentExtractor.render_modifiers(call)})
      else
        %(data-mochi-#{call.event}="#{handler}"#{EventArgumentExtractor.render_modifiers(call)})
      end
    end

    expressions = parser.scan(template, "each", scope_names, validate: true)
    expressions.each do |expression|
      inner = expression.source
      if CONTROL_KEYWORDS.includes?(inner) || CONTROL_PREFIXES.any? { |prefix| inner.starts_with?(prefix) }
        raise TemplateExpressionError.new(
          "template block '#{inner}' is not supported inside an each row yet",
          expression.span
        )
      end
    end

    sentinel_template = template
    replacements = [] of Tuple(Int32, Int32, String)
    expressions.each_with_index do |expression, slot|
      replacements << {expression.template_start, expression.template_end, sentinel(slot)}
    end
    replacements.sort_by! { |replacement| -replacement[0] }
    replacements.each do |start, finish, token|
      sentinel_template = sentinel_template.byte_slice(0, start) +
                          token +
                          sentinel_template.byte_slice(finish, sentinel_template.bytesize - finish)
    end

    classification = classify_slots(sentinel_template, context)
    bindings = [] of EachRowBindingDescriptor
    expressions.each_with_index do |expression, slot|
      kind, attr_name = classification[slot]? || raise TemplateExpressionError.new(
        "each row expression was lost while parsing in <#{context.tag}> context; check the surrounding HTML nesting",
        expression.span || row_span
      )
      trusted_source = TemplateExpressionParser.trusted_markup_source(expression.source)
      if trusted_source && kind == "attr"
        raise TemplateExpressionError.new(
          "Mochi.raw is only supported in text content, not in the #{attr_name} attribute",
          expression.span
        )
      end
      if trusted_source
        kind = "html"
      end
      bindings << EachRowBindingDescriptor.new(
        slot,
        kind,
        attr_name,
        trusted_source || expression.source,
        expression.span,
        !trusted_source.nil?,
        kind == "attr" && attr_name ? HtmlAttributes.kind(attr_name) : nil
      )
    end

    children = children_blocks.map do |child|
      compile_row(child, parser, scope, child_contexts[child.id]? || context, ids)
    end
    conditionals = blocks.map do |block|
      id = conditional_ids[block.id]
      branch_context = context_for_marker(template, "mochi-cond-#{id}", context, parser)
      conditions = block.branches.map(&.condition)
      conditions.each { |condition| parser.validate_source!(condition, "row condition") if condition }
      branches = block.branches.map do |branch|
        span = parser.locator.try(&.locate(branch.condition || branch.content)) || row_span
        compile_fragment(branch.content, ids.take, parser, scope, branch_context, ids, span)
      end
      EachRowConditional.new(id, conditions, branches, parser.locator.try(&.locate(block.condition)))
    end
    EachRowFragment.new(
      fragment_id,
      inert_svg_attributes(sentinel_template, context),
      bindings,
      row_events,
      children,
      scope,
      row_span,
      conditional_attributes.conditionals,
      hash_attributes.hashes,
      context.tag,
      context.namespace,
      conditionals
    )
  end

  # SVG numeric/path parsers reject sentinel strings even in detached trees.
  # Keep dynamic attributes inert until the loader applies evaluated slots.
  private def self.inert_svg_attributes(template : String, context : EachRowDomContext) : String
    root = fragment_root(template, context)
    return template unless root
    changed = defer_svg_attributes(root, context.namespace)
    changed ? root.inner_html : template
  end

  private def self.defer_svg_attributes(node : Lexbor::Node, namespace : String) : Bool
    tag = node.tag_name.downcase
    namespace = "svg" if tag == "svg"
    changed = false
    if namespace == "svg" && (attrs = node.attributes)
      attrs.to_a.each_with_index do |(name, value), index|
        next unless value.includes?(SENTINEL_START)
        node.attribute_remove(name)
        node.attribute_add("data-mochi-row-attr-#{index}", {"name" => name, "template" => value}.to_json)
        changed = true
      end
    end
    namespace = "html" if tag == "foreignobject"
    node.children.each { |child| changed = defer_svg_attributes(child, namespace) || changed }
    changed
  end

  private def self.rewrite_row_attribute_helpers(
    template : String,
    block_id : Int32,
    scope : Array(EachRowScope),
  ) : String
    args = scope.flat_map { |entry| [entry.item_name, entry.index_name] }.join(", ")
    template.gsub(/\{__mochi_attr_cond_(\d+)\}/) do |_, match|
      "{__mochi_each_#{block_id}_attr_cond_#{match[1]}(#{args})}"
    end.gsub(/\{__mochi_attr_hash_(\d+)\}/) do |_, match|
      "{__mochi_each_#{block_id}_attr_hash_#{match[1]}(#{args})}"
    end
  end

  # The transpiler normalizes event calls before each blocks are extracted.
  # Recover that normalized argument list here, attach it to the matching event
  # attribute, and remove the descriptor so the browser never receives
  # expression text for list rows.
  private def self.extract_event_arguments(
    template : String,
    parser : TemplateExpressionParser,
  ) : Tuple(String, Hash(Int32, Array(EventArgumentDescriptor)))
    arguments_by_marker = {} of Int32 => Array(EventArgumentDescriptor)
    attributes = TemplateAttributes.scan(template, parser)
    result = String.build do |io|
      cursor = 0
      attributes.each_with_index do |attribute, index|
        event = attribute.name
        next unless EventArgumentExtractor::EVENT_NAME.matches?(event)
        next unless metadata = attributes[index + 1]?
        event_name = EventCall.new(event, "", [] of String).event
        next unless metadata.name == "data-mochi-args-#{event_name}"
        # The first pass emits the descriptor immediately after its event.
        next unless template.byte_slice(attribute.finish, metadata.start - attribute.finish).strip.empty?
        handler = attribute.value(template).lchop('{').rchop('}')
        raw = unescape_attribute(metadata.value(template))
        io << template.byte_slice(cursor, attribute.start - cursor)
        marker = arguments_by_marker.size
        begin
          parsed = JSON.parse(raw).as_a
          arguments_by_marker[marker] = parsed.map do |item|
            EventArgumentDescriptor.from_json_object(item)
          end
        rescue ex
          raise "invalid list row event arguments for #{event}: #{ex.message}"
        end

        io << event << "=\"{__mochi_row_args_" << marker << "__" << handler << "}\""
        cursor = metadata.finish
      end
      io << template.byte_slice(cursor, template.bytesize - cursor)
    end
    {result, arguments_by_marker}
  end

  private def self.unescape_attribute(value : String) : String
    HTML.unescape(value)
  end

  private def self.scope_names_for(scope : Array(EachRowScope)) : Array(String)
    names = [] of String
    scope.each do |entry|
      names << entry.item_name unless names.includes?(entry.item_name)
      names << entry.index_name unless names.includes?(entry.index_name)
      names << "index" unless names.includes?("index")
    end
    names
  end

  # Uses the HTML parser only to decide whether a slot is text or an attribute
  # value. Text is the default regardless of surrounding whitespace. The
  # caller upgrades a slot to HTML only when `Mochi.raw(...)` wraps it.
  private def self.classify_slots(
    template : String,
    context : EachRowDomContext,
  ) : Hash(Int32, Tuple(String, String?))
    result = {} of Int32 => Tuple(String, String?)
    body = Lexbor.new(wrap_in_context(template, context)).body
    return result unless body

    walk_classify(body, result)
    result
  end

  def self.wrap_in_context(template : String, context : EachRowDomContext) : String
    tag = context.tag.downcase
    if context.namespace == "svg"
      return tag == "svg" ? "<svg>#{template}</svg>" : "<svg><#{tag}>#{template}</#{tag}></svg>"
    end

    case tag
    when "table"
      "<table>#{template}</table>"
    when "tbody", "thead", "tfoot"
      "<table><#{tag}>#{template}</#{tag}></table>"
    when "tr"
      "<table><tbody><tr>#{template}</tr></tbody></table>"
    when "td", "th"
      "<table><tbody><tr><#{tag}>#{template}</#{tag}></tr></tbody></table>"
    when "select"
      "<select>#{template}</select>"
    when "optgroup"
      "<select><optgroup>#{template}</optgroup></select>"
    when "option"
      "<select><option>#{template}</option></select>"
    else
      "<#{tag}>#{template}</#{tag}>"
    end
  end

  def self.fragment_root(template : String, context : EachRowDomContext) : Lexbor::Node?
    body = Lexbor.new(wrap_in_context(template, context)).body
    return body if context.tag == "body"
    body.try(&.css(context.tag).first?)
  end

  private def self.context_for_marker(template : String, text : String, context : EachRowDomContext, parser : TemplateExpressionParser) : EachRowDomContext
    body = Lexbor.new(wrap_in_context(parser.html_safe(template), context)).body
    marker = body.try { |root| find_comment(root, text) }
    parent = marker.try(&.parent)
    return context unless parent
    ancestors = [] of Lexbor::Node
    ancestor = parent
    while ancestor
      ancestors << ancestor
      ancestor = ancestor.parent
    end
    namespace = context.namespace
    ancestors.reverse_each do |node|
      tag = node.tag_name.downcase
      namespace = "svg" if tag == "svg"
      namespace = "html" if tag == "foreignobject"
    end
    EachRowDomContext.new(parent.tag_name, namespace)
  end

  private def self.contexts_for_children(
    template : String,
    children : Array(EachBlock),
    context : EachRowDomContext,
    parser : TemplateExpressionParser,
  ) : Hash(Int32, EachRowDomContext)
    return {} of Int32 => EachRowDomContext if children.empty?

    result = {} of Int32 => EachRowDomContext
    children.each do |child|
      result[child.id] = context_for_marker(template, "mochi-each-#{child.id}", context, parser)
    end
    result
  end

  private def self.find_comment(node : Lexbor::Node, text : String) : Lexbor::Node?
    return node if node.tag_name == "_em_comment" && node.tag_text == text
    node.children.each do |child|
      found = find_comment(child, text)
      return found if found
    end
    nil
  end

  def self.validate_context_nesting(
    template : String,
    context : EachRowDomContext,
    span : TemplateSourceSpan?,
    parser : TemplateExpressionParser = TemplateExpressionParser.new,
  ) : Nil
    return if context.namespace == "svg"
    template = parser.html_safe(template)

    parent_tag = context.tag.downcase
    invalid_tag = root_tags(template).find do |tag|
      case tag
      when "tr"
        !{"table", "tbody", "thead", "tfoot"}.includes?(parent_tag)
      when "td", "th"
        parent_tag != "tr"
      when "tbody", "thead", "tfoot", "caption", "colgroup"
        parent_tag != "table"
      when "col"
        parent_tag != "colgroup"
      when "option", "optgroup"
        !{"select", "optgroup"}.includes?(parent_tag)
      else
        false
      end
    end
    if invalid_tag
      raise TemplateExpressionError.new(
        "<#{invalid_tag}> cannot be a row root inside <#{context.tag}>; use valid HTML nesting for this row",
        span
      )
    end

    allowed = case context.tag.downcase
              when "table"
                ["caption", "colgroup", "thead", "tbody", "tfoot", "tr", "style", "script", "template"]
              when "tbody", "thead", "tfoot"
                ["tr", "style", "script", "template"]
              when "tr"
                ["td", "th", "style", "script", "template"]
              when "select"
                ["option", "optgroup", "hr", "script", "template"]
              when "optgroup"
                ["option", "script", "template"]
              when "colgroup"
                ["col", "template"]
              else
                return
              end

    root_tags(template).each do |tag|
      next if allowed.includes?(tag)
      raise TemplateExpressionError.new(
        "<#{tag}> cannot be a row root inside <#{context.tag}>; use valid HTML nesting for this row",
        span
      )
    end
  end

  private def self.root_tags(template : String) : Array(String)
    tags = [] of String
    depth = 0
    template.scan(/<\/?([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*>/m) do |match|
      token = match[0]
      name = match[1].downcase
      closing = token.starts_with?("</")
      self_closing = token.ends_with?("/>")
      if closing
        depth -= 1 if depth > 0
      else
        tags << name if depth == 0
        unless self_closing || {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}.includes?(name)
          depth += 1
        end
      end
    end
    tags
  end

  private def self.walk_classify(node : Lexbor::Node, result : Hash(Int32, Tuple(String, String?)))
    if node.tag_name == "_text"
      text = node.tag_text
      slots = slots_in(text)
      return if slots.empty?

      slots.each do |slot|
        result[slot] = {"text", nil}
      end
      return
    end

    if attrs = node.attributes
      attrs.each do |name, value|
        slots_in(value).each do |slot|
          result[slot] = {"attr", name}
        end
      end
    end

    node.children.each { |child| walk_classify(child, result) }
  end

  private def self.slots_in(text : String) : Array(Int32)
    slots = [] of Int32
    text.scan(SENTINEL_PATTERN) do |match|
      slots << match[1].to_i
    end
    slots
  end
end
