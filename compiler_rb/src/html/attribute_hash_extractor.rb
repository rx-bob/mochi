# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class ExtractedAttributeHash < T::Struct
  const :id, Integer
  const :original_string, String
  const :attribute_name, String
end

class AttributeHashResult < T::Struct
  const :html, String
  const :hashes, T::Array[ExtractedAttributeHash]
end

class AttributeHashExtractor
  extend T::Sig

  REGEX = T.let(
    /([a-zA-Z0-9_\-\:]+)\s*=\s*(?:(["'])(\{\{.*?\}\})\2|\{\{(.*?)\}\})/m,
    Regexp
  )

  sig { params(html: String).returns(AttributeHashResult) }
  def self.process(html)
    hashes = T::Array[ExtractedAttributeHash].new
    next_id = 0

    processed_html = html.gsub(REGEX) do |_match|
      attr_name = $1.to_s
      attr_value = $3 ? $3.to_s : "{{#{$4}}}"

      hash = ExtractedAttributeHash.new(id: next_id, original_string: attr_value, attribute_name: attr_name)
      hashes << hash

      replacement_value = "{__mochi_attr_hash_#{next_id}}"
      next_id += 1

      "#{attr_name}=\"#{replacement_value}\""
    end

    AttributeHashResult.new(html: processed_html, hashes: hashes)
  end
end
