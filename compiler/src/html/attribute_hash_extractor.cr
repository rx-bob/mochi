require "./attribute_scope_mask"

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
  def self.process(html : String) : AttributeHashResult
    hashes = [] of ExtractedAttributeHash
    return AttributeHashResult.new(html, hashes) unless html.includes?("{{")
    protected_html, each_blocks = AttributeScopeMask.protect(html)
    next_id = 0

    # 1. Unquoted attribute={{...}}
    unquoted_regex = /([a-zA-Z0-9_\-\:]+)\s*=\s*\{\{(.*?)\}\}/m
    processed_html = protected_html.gsub(unquoted_regex) do |_, m|
      attr_name = m[1]
      attr_value = "{{#{m[2]?}}}"
      cond = ExtractedAttributeHash.new(next_id, attr_value, attr_name)
      hashes << cond
      replacement_value = "{__mochi_attr_hash_#{next_id}}"
      next_id += 1
      "#{attr_name}=\"#{replacement_value}\""
    end

    # 2. Quoted attribute="... {{...}} ..." (supports standalone or mixed with static tokens)
    quoted_regex = /([a-zA-Z0-9_\-\:]+)\s*=\s*(["'])((?:(?!\2).)*?\{\{.*?\}\}(?:(?!\2).)*?)\2/m
    processed_html = processed_html.gsub(quoted_regex) do |_, m|
      attr_name = m[1]
      quote = m[2]
      inner = m[3]
      replaced_inner = inner.gsub(/\{\{(.*?)\}\}/m) do |hash_match|
        cond = ExtractedAttributeHash.new(next_id, hash_match, attr_name)
        hashes << cond
        rep = "{__mochi_attr_hash_#{next_id}}"
        next_id += 1
        rep
      end
      "#{attr_name}=#{quote}#{replaced_inner}#{quote}"
    end

    AttributeHashResult.new(AttributeScopeMask.restore(processed_html, each_blocks), hashes)
  end
end
