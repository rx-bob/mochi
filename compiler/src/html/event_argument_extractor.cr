require "./event_argument"
require "./template_expression"

class EventArgumentExtractor
  EVENT_START = /(on[a-z]+)\s*=\s*(["'])?\{/

  # Rewrites event attributes with call arguments into a plain method name plus
  # a JSON descriptor list. Keeping the descriptors on the element lets the
  # loader pass typed values to the VM without evaluating Ruby in JavaScript.
  def self.process(html : String, locator : TemplateSourceLocator? = nil) : String
    parser = TemplateExpressionParser.new(locator)
    String.build do |io|
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

        io << render_event_attribute(parser, event_name, content)
        cursor = attribute_end
      end

      io << html.byte_slice(cursor, html.bytesize - cursor)
    end
  end

  private def self.render_event_attribute(parser : TemplateExpressionParser, event_name : String, content : String) : String
    method_name, arguments = parser.parse_call(content)
    validate_arguments(parser, arguments)
    event = event_name.starts_with?("on") ? event_name[2..] : event_name

    String.build do |io|
      io << event_name << "=\"{"
      io << method_name << "}\""

      unless arguments.empty?
        descriptors = arguments.map { |argument| EventArgumentDescriptor.parse(argument) }
        io << " data-mochi-args-" << event << "=\""
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
