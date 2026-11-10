require "./event_argument"

class EventArgumentExtractor
  EVENT_START = /(on[a-z]+)\s*=\s*(["'])?\{/

  # Rewrites event attributes with call arguments into a plain method name plus
  # a JSON descriptor list. Keeping the descriptors on the element lets the
  # loader pass typed values to the VM without evaluating Ruby in JavaScript.
  def self.process(html : String) : String
    String.build do |io|
      cursor = 0

      while match = EVENT_START.match(html, cursor)
        start = match.begin(0)
        io << html[cursor...start]

        event_name = match[1].downcase
        quote = match[2]?
        content_start = match.end(0)
        close = find_closing_brace(html, content_start)

        unless close
          io << html[start...]
          cursor = html.size
          break
        end

        content = html[content_start...close].strip
        attribute_end = close + 1
        if quote && attribute_end < html.size && html[attribute_end] == quote[0]
          attribute_end += 1
        end

        io << render_event_attribute(event_name, content)
        cursor = attribute_end
      end

      io << html[cursor...]
    end
  end

  private def self.render_event_attribute(event_name : String, content : String) : String
    method_name, arguments = parse_call(content)
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

  private def self.escape_attribute(value : String) : String
    value.gsub('&', "&amp;")
      .gsub('"', "&quot;")
      .gsub('<', "&lt;")
      .gsub('>', "&gt;")
  end

  private def self.parse_call(content : String) : Tuple(String, Array(String))
    text = content.strip
    open = find_unquoted(text, '(')
    return {text, [] of String} unless open

    close = matching_paren(text, open)
    return {text, [] of String} unless close == text.size - 1

    method_name = text[0...open].strip
    return {text, [] of String} if method_name.empty?

    arguments = split_arguments(text[(open + 1)...close])
    {method_name, arguments}
  end

  private def self.find_unquoted(text : String, needle : Char) : Int32?
    quote = nil
    escaped = false

    text.each_char_with_index do |char, index|
      if current = quote
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == current
          quote = nil
        end
      elsif char == '\'' || char == '"'
        quote = char
      elsif char == needle
        return index
      end
    end

    nil
  end

  private def self.matching_paren(text : String, open : Int32) : Int32?
    depth = 0
    quote = nil
    escaped = false
    index = open

    while index < text.size
      char = text[index]
      if current = quote
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == current
          quote = nil
        end
      elsif char == '\'' || char == '"'
        quote = char
      elsif char == '('
        depth += 1
      elsif char == ')'
        depth -= 1
        return index if depth == 0
      end
      index += 1
    end

    nil
  end

  # Splits on top-level commas and keeps commas inside strings, calls, arrays,
  # and hashes attached to their argument.
  private def self.split_arguments(text : String) : Array(String)
    arguments = [] of String
    current = ""
    depth = 0
    quote = nil
    escaped = false

    text.each_char do |char|
      if current_quote = quote
        current += char
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == current_quote
          quote = nil
        end
        next
      end

      case char
      when '\'', '"'
        quote = char
        current += char
      when '(', '[', '{'
        depth += 1
        current += char
      when ')', ']', '}'
        depth -= 1 if depth > 0
        current += char
      when ','
        if depth == 0
          argument = current.strip
          arguments << argument unless argument.empty?
          current = ""
        else
          current += char
        end
      else
        current += char
      end
    end

    argument = current.strip
    arguments << argument unless argument.empty?
    arguments
  end

  private def self.find_closing_brace(html : String, start : Int32) : Int32?
    depth = 0
    quote = nil
    escaped = false
    index = start

    while index < html.size
      char = html[index]
      if current = quote
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == current
          quote = nil
        end
      elsif char == '\'' || char == '"'
        quote = char
      elsif char == '{'
        depth += 1
      elsif char == '}'
        return index if depth == 0
        depth -= 1
      end
      index += 1
    end

    nil
  end
end
