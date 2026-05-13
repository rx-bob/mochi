# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class ExtractedAttributeConditional < T::Struct
  const :id, Integer
  const :original_string, String
  const :attribute_name, String
end

class AttributeConditionalResult < T::Struct
  const :html, String
  const :conditionals, T::Array[ExtractedAttributeConditional]
end

class AttributeConditionalExtractor
  extend T::Sig

  REGEX = T.let(
    /([a-zA-Z0-9_\-\:]+)\s*=\s*(["'])((?:(?!\2).)*(?:\{if |\{unless )(?:(?!\2).)*)\2/m,
    Regexp
  )

  sig { params(html: String).returns(AttributeConditionalResult) }
  def self.process(html)
    conditionals = T::Array[ExtractedAttributeConditional].new
    next_id = 0

    processed_html = html.gsub(REGEX) do |_match|
      attr_name = $1.to_s
      quote = $2.to_s
      attr_value = $3.to_s

      cond = ExtractedAttributeConditional.new(id: next_id, original_string: attr_value, attribute_name: attr_name)
      conditionals << cond

      replacement_value = "{__mochi_attr_cond_#{next_id}}"
      next_id += 1

      "#{attr_name}=#{quote}#{replacement_value}#{quote}"
    end

    AttributeConditionalResult.new(html: processed_html, conditionals: conditionals)
  end
end
