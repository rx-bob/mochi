require "json"
require "lexbor"
require "./each_processor"
require "./each_row_template"
require "./event_argument_extractor"
require "./html_attributes"
require "./template_expression"

# Compiles one each block into a static row template plus evaluated value
# slots and nested row trees. Expression text stays in the compiler; the
# browser manifest receives only descriptors and the generated Ruby row getter
# evaluates every value inside the VM.
class EachRowCompiler
  SENTINEL_START   = "\u{E002}"
  SENTINEL_END     = "\u{E003}"
  SENTINEL_PATTERN = Regex.new(SENTINEL_START + "([0-9]+)" + SENTINEL_END)
  EVENT_WITH_ARGS  = /(on:?[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*)="\{([a-zA-Z0-9_!?]+)\}"\s+data-mochi-args-[a-zA-Z0-9_-]+="([^"]*)"/m
  ARG_MARKER       = /\A__mochi_row_args_(\d+)__(.*)\z/m
  CONTROL_PREFIXES = ["if ", "unless ", "elsif ", "each "]
  CONTROL_KEYWORDS = ["else", "end"]

  def self.sentinel(slot : Int32) : String
    "#{SENTINEL_START}#{slot}#{SENTINEL_END}"
  end

  def self.compile(
    block : EachBlock,
    parser : TemplateExpressionParser,
  ) : EachRowTemplate
    compile_row(block, parser, [] of EachRowScope)
  end

  private def self.compile_row(
    block : EachBlock,
    parser : TemplateExpressionParser,
    parent_scope : Array(EachRowScope),
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
    scope_names = scope_names_for(scope)
    template = replace_nested_blocks(block)
    if template.matches?(/\sref\s*=/)
      raise TemplateExpressionError.new(
        "ref is not supported inside each rows; place named refs in the static component template",
        row_span
      )
    end
    template, preprocessed_args = extract_event_arguments(template)
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
        wrapper = "__mochi_each_#{block.id}_ev_#{event_index}"
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

    classification = classify_slots(sentinel_template)
    bindings = [] of EachRowBindingDescriptor
    expressions.each_with_index do |expression, slot|
      kind, attr_name = classification[slot]? || {"text", nil}
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

    children = block.children.map do |child|
      compile_row(child, parser, scope)
    end

    EachRowTemplate.new(
      block.id,
      block.loop_def.array_name,
      item_name,
      index_name,
      declared_index,
      sentinel_template,
      bindings,
      row_events,
      children,
      scope,
      key_expression,
      row_span
    )
  end

  private def self.replace_nested_blocks(block : EachBlock) : String
    template = block.content.dup
    block.children.sort_by { |child| -child.start_pos }.each do |child|
      rel_start = child.start_pos - block.content_start_pos
      rel_end = child.end_pos - block.content_start_pos
      next if rel_start < 0 || rel_end > template.size || rel_start > rel_end

      template = EachProcessor.replace_range(
        template,
        rel_start,
        rel_end,
        "<!--mochi-each-#{child.id}-->"
      )
    end
    template
  end

  # The transpiler normalizes event calls before each blocks are extracted.
  # Recover that normalized argument list here, attach it to the matching event
  # attribute, and remove the descriptor so the browser never receives
  # expression text for list rows.
  private def self.extract_event_arguments(
    template : String,
  ) : Tuple(String, Hash(Int32, Array(EventArgumentDescriptor)))
    arguments_by_marker = {} of Int32 => Array(EventArgumentDescriptor)
    result = String.build do |io|
      cursor = 0
      template.scan(EVENT_WITH_ARGS) do |match|
        start = TemplateExpressionParser.char_to_byte(template, match.begin(0))
        finish = TemplateExpressionParser.char_to_byte(template, match.end(0))
        io << template.byte_slice(cursor, start - cursor)

        event = match[1]
        handler = match[2]
        raw = unescape_attribute(match[3])
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
        cursor = finish
      end
      io << template.byte_slice(cursor, template.bytesize - cursor)
    end
    {result, arguments_by_marker}
  end

  private def self.unescape_attribute(value : String) : String
    value.gsub("&quot;", "\"")
      .gsub("&#39;", "'")
      .gsub("&lt;", "<")
      .gsub("&gt;", ">")
      .gsub("&amp;", "&")
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
  private def self.classify_slots(template : String) : Hash(Int32, Tuple(String, String?))
    result = {} of Int32 => Tuple(String, String?)
    body = Lexbor.new(template).body
    return result unless body

    walk_classify(body, result)
    result
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
