require "./attribute_scope_mask"
require "./template_attributes"

class ExtractedAttributeHash
  property id : Int32
  property original_string : String
  property attribute_name : String

  def initialize(@id : Int32, @original_string : String, @attribute_name : String)
  end
end

class AttributeHashResult
  property html : String
  property hashes : Array(ExtractedAttributeHash)

  def initialize(@html : String, @hashes : Array(ExtractedAttributeHash))
  end
end

class AttributeHashExtractor
  def self.process(html : String, parser : TemplateExpressionParser = TemplateExpressionParser.new) : AttributeHashResult
    hashes = [] of ExtractedAttributeHash
    return AttributeHashResult.new(html, hashes) unless html.includes?("{{")
    protected_html, each_blocks = AttributeScopeMask.protect(html)
    processed_html = TemplateAttributes.rewrite(protected_html, parser) do |attribute|
      value = attribute.value(protected_html)
      changed = false
      replaced = String.build do |io|
        i = 0
        while i < value.bytesize
          if value.byte_at(i) == 123_u8 && (close = TemplateExpressionParser.matching_brace(value, i))
            token = value.byte_slice(i, close - i + 1)
            if token.starts_with?("{{") && token.ends_with?("}}") &&
               (attribute.quote.nil? || parser.hash_literal_intent?(token[1...-1]))
              parser.validate_source!(token[1...-1], "attribute hash")
              id = hashes.size
              hashes << ExtractedAttributeHash.new(id, token, attribute.name)
              io << "{__mochi_attr_hash_#{id}}"
              changed = true
            else
              io << token
            end
            i = close + 1
          else
            io.write_byte(value.byte_at(i))
            i += 1
          end
        end
      end
      next nil unless changed
      quote = attribute.quote.try(&.chr) || '"'
      "#{attribute.name}=#{quote}#{replaced}#{quote}"
    end

    AttributeHashResult.new(AttributeScopeMask.restore(processed_html, each_blocks), hashes)
  end
end
