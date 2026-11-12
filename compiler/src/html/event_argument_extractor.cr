require "./event_argument"
require "./template_expression"

# One event attribute discovered in a template. The replacement callback in
# `rewrite` decides whether the DOM receives a plain handler name or a compiled
# row wrapper symbol.
struct EventCall
  getter event_name : String
  getter method_name : String
  getter arguments : Array(String)
  getter span : TemplateSourceSpan?

  def initialize(
    @event_name : String,
    @method_name : String,
    @arguments : Array(String),
    @span : TemplateSourceSpan? = nil,
  )
  end

  def event : String
    if event_name.starts_with?("on:")
      event_name[3..]
    elsif event_name.starts_with?("on")
      event_name[2..]
    else
      event_name
    end
  end

  # `on:<event>` is a compiled parent/child connection. `on<event>` retains
  # the native DOM event behavior.
  def component? : Bool
    event_name.starts_with?("on:")
  end
end

class EventArgumentExtractor
  EVENT_START = /(on:?[a-z][a-z0-9_-]*)\s*=\s*(["'])?\{/

  # Rewrites event attributes with call arguments into a plain method name plus
  # a JSON descriptor list. Keeping the descriptors on the element lets the
  # loader pass typed values to the VM without evaluating Ruby in JavaScript.
  def self.process(html : String, locator : TemplateSourceLocator? = nil) : String
    rewritten, _calls = rewrite(html, locator) do |call|
      render_event_attribute(call)
    end
    rewritten
  end

  # Rewrites every event attribute and returns the calls that were found.
  # List rows use this to replace the attribute with a generated Ruby wrapper
  # symbol instead of shipping argument expressions to the browser.
  def self.rewrite(
    html : String,
    locator : TemplateSourceLocator? = nil,
    &replacement : EventCall -> String
  ) : Tuple(String, Array(EventCall))
    parser = TemplateExpressionParser.new(locator)
    calls = [] of EventCall
    result = String.build do |io|
      cursor = 0

      while match = EVENT_START.match(html, TemplateExpressionParser.byte_to_char(html, cursor))
        start = TemplateExpressionParser.char_to_byte(html, match.begin(0))
        io << html.byte_slice(cursor, start - cursor)

        event_name = match[1].downcase
        quote = match[2]?
        content_start = TemplateExpressionParser.char_to_byte(html, match.end(0))
        close = TemplateExpressionParser.matching_brace(html, content_start - 1)

        unless close
          io << html.byte_slice(start, html.bytesize - start)
          cursor = html.bytesize
          break
        end

        content = html.byte_slice(content_start, close - content_start).strip
        attribute_end = close + 1
        if quote && attribute_end < html.bytesize && html.byte_at(attribute_end) == quote[0].ord.to_u8
          attribute_end += 1
        end

        method_name, arguments = parser.parse_call(content)
        validate_arguments(parser, arguments)
        call = EventCall.new(event_name, method_name, arguments, locator.try(&.locate(content)))
        calls << call
        io << replacement.call(call)
        cursor = attribute_end
      end

      io << html.byte_slice(cursor, html.bytesize - cursor)
    end
    {result, calls}
  end

  private def self.render_event_attribute(call : EventCall) : String
    String.build do |io|
      io << call.event_name << "=\"{"
      io << call.method_name << "}\""

      unless call.arguments.empty?
        descriptors = call.arguments.map { |argument| EventArgumentDescriptor.parse(argument) }
        io << " data-mochi-args-" << call.event << "=\""
        io << escape_attribute(EventArgumentDescriptor.array_json(descriptors))
        io << "\""
      end
    end
  end

  private def self.validate_arguments(parser : TemplateExpressionParser, arguments : Array(String))
    arguments.each do |argument|
      next if argument == "$event" || argument == "event" || argument == "$element" || argument == "element"
      parser.validate_source!(argument, "event argument")
    end
  end

  private def self.escape_attribute(value : String) : String
    value.gsub('&', "&amp;")
      .gsub('"', "&quot;")
      .gsub('<', "&lt;")
      .gsub('>', "&gt;")
  end
end
