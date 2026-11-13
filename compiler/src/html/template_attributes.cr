require "./template_expression"

# Byte ranges in authored template text, before an HTML parser can interpret
# quotes or angle brackets belonging to Ruby expressions.
struct TemplateAttribute
  getter name : String
  getter start : Int32
  getter finish : Int32
  getter value_start : Int32
  getter value_end : Int32
  getter quote : UInt8?

  def initialize(@name, @start, @finish, @value_start, @value_end, @quote)
  end

  def value(html : String) : String
    html.byte_slice(value_start, value_end - value_start)
  end
end

class TemplateAttributes
  def self.scan(html : String, parser : TemplateExpressionParser = TemplateExpressionParser.new) : Array(TemplateAttribute)
    attributes = [] of TemplateAttribute
    i = 0
    while i < html.bytesize
      if html.byte_at(i) == 123_u8
        i = placeholder_end(html, i, parser)
        next
      end
      unless html.byte_at(i) == 60_u8 && i + 1 < html.bytesize && letter?(html.byte_at(i + 1))
        if html.byte_slice(i, Math.min(4, html.bytesize - i)) == "<!--"
          i = (html.byte_index("-->", i).try { |ending| ending + 3 }) || html.bytesize
        else
          i += 1
        end
        next
      end
      i += 1
      while i < html.bytesize && name_byte?(html.byte_at(i))
        i += 1
      end
      while i < html.bytesize
        while i < html.bytesize && TemplateExpressionParser.whitespace?(html.byte_at(i))
          i += 1
        end
        break if i >= html.bytesize
        if html.byte_at(i) == 62_u8
          i += 1
          break
        end
        unless name_byte?(html.byte_at(i))
          i += 1
          next
        end
        start = i
        while i < html.bytesize && name_byte?(html.byte_at(i))
          i += 1
        end
        name = html.byte_slice(start, i - start)
        while i < html.bytesize && TemplateExpressionParser.whitespace?(html.byte_at(i))
          i += 1
        end
        next unless i < html.bytesize && html.byte_at(i) == 61_u8
        i += 1
        while i < html.bytesize && TemplateExpressionParser.whitespace?(html.byte_at(i))
          i += 1
        end
        break if i >= html.bytesize
        quote = [34_u8, 39_u8].includes?(html.byte_at(i)) ? html.byte_at(i) : nil
        i += 1 if quote
        value_start = i
        while i < html.bytesize
          byte = html.byte_at(i)
          break if quote ? byte == quote : (TemplateExpressionParser.whitespace?(byte) || byte == 62_u8)
          i = byte == 123_u8 ? placeholder_end(html, i, parser) : i + 1
        end
        value_end = i
        i += 1 if quote && i < html.bytesize
        attributes << TemplateAttribute.new(name, start, i, value_start, value_end, quote)
      end
    end
    attributes
  end

  def self.rewrite(html : String, parser : TemplateExpressionParser = TemplateExpressionParser.new,
                   &block : TemplateAttribute -> String?) : String
    String.build do |io|
      cursor = 0
      scan(html, parser).each do |attribute|
        next unless replacement = yield attribute
        io << html.byte_slice(cursor, attribute.start - cursor) << replacement
        cursor = attribute.finish
      end
      io << html.byte_slice(cursor)
    end
  end

  private def self.placeholder_end(html : String, start : Int32, parser : TemplateExpressionParser) : Int32
    if close = TemplateExpressionParser.matching_brace(html, start)
      return close + 1
    end
    # Doubled braces are also the literal-brace escape, not necessarily a hash.
    return start + 2 if html.byte_slice(start, Math.min(2, html.bytesize - start)) == "{{"
    snippet = html.byte_slice(start, Math.min(60, html.bytesize - start))
    raise TemplateExpressionError.new("unclosed template placeholder near #{snippet.inspect}", parser.locator.try(&.locate(snippet, start)))
  end

  private def self.letter?(byte : UInt8) : Bool
    (65_u8 <= byte <= 90_u8) || (97_u8 <= byte <= 122_u8)
  end

  private def self.name_byte?(byte : UInt8) : Bool
    letter?(byte) || (48_u8 <= byte <= 57_u8) || [95_u8, 45_u8, 58_u8, 46_u8].includes?(byte)
  end
end
