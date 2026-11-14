require "./attribute_scope_mask"
require "./template_attributes"

class ExtractedAttributeConditional
  property id : Int32
  property original_string : String
  property attribute_name : String

  def initialize(@id : Int32, @original_string : String, @attribute_name : String)
  end
end

class AttributeConditionalResult
  property html : String
  property conditionals : Array(ExtractedAttributeConditional)

  def initialize(@html : String, @conditionals : Array(ExtractedAttributeConditional))
  end
end

class AttributeConditionalExtractor
  def self.process(html : String, parser : TemplateExpressionParser = TemplateExpressionParser.new) : AttributeConditionalResult
    conditionals = [] of ExtractedAttributeConditional
    return AttributeConditionalResult.new(html, conditionals) unless html.includes?("{if ") || html.includes?("{unless ")
    protected_html, each_blocks = AttributeScopeMask.protect(html)
    processed_html = TemplateAttributes.rewrite(protected_html, parser) do |attribute|
      value = attribute.value(protected_html)
      expressions = parser.scan(value, "attribute", validate: false)
      next nil unless expressions.any? { |expression| expression.source.starts_with?("if ") || expression.source.starts_with?("unless ") }
      expressions.each do |expression|
        source = expression.source
        next if source == "else" || source == "end"
        source = source.sub(/\A(?:if|elsif|unless)\s+/, "")
        parser.validate_source!(source, "attribute")
      end
      id = conditionals.size
      conditionals << ExtractedAttributeConditional.new(id, value, attribute.name)
      quote = attribute.quote.try(&.chr) || '"'
      "#{attribute.name}=#{quote}{__mochi_attr_cond_#{id}}#{quote}"
    end

    AttributeConditionalResult.new(AttributeScopeMask.restore(processed_html, each_blocks), conditionals)
  end
end
