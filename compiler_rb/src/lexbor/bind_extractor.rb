# typed: false
# frozen_string_literal: true

require "lexbor/bindings"

class BindResult
  attr_reader :html, :bindings

  def initialize(html, bindings)
    @html = html
    @bindings = bindings
  end

  def to_s
    "BindResult(html: #{html.inspect}, bindings: #{@bindings.inspect})"
  end
end

class BindExtractor
  PREFIX = "bind:"

  def self.get_key_no_prefix(key)
    key[PREFIX.length..]
  end

  def self.get_bind_key(val)
    if val.size > 0 && val[0] == "{" && val[-1] == "}"
      # value is sth like {count}
      val[1..-2]
    else
      val
    end
  end

  def self.extract(html)
    cleaned_html_no_skeleton = ""
    bindings = {}

    doc = Lexbor::Document.parse(html)
    tags = doc.root.all_elements

    tags.each do |tag|
      attrs_to_remove = []
      attrs_to_add = {}

      tag.attributes.each do |key, val|
        if key.start_with?(PREFIX)
          attrs_to_remove << key
          key_no_prefix = get_key_no_prefix(key)
          attrs_to_add[key_no_prefix] = val

          bind_key = get_bind_key(val)
          if bind_key.size > 0
            bindings[bind_key] = key_no_prefix
          end
        end
      end

      attrs_to_remove.each do |attr_name_to_remove|
        tag.attribute_remove(attr_name_to_remove)
      end

      attrs_to_add.each do |new_key, new_value|
        tag.attribute_add(new_key, new_value)
      end
    end

    cleaned_html_full = doc.to_html

    body_open_tag = "<body>"
    body_close_tag = "</body>"
    body_open_index = cleaned_html_full.index(body_open_tag)
    body_end_index = cleaned_html_full.index(body_close_tag)

    cleaned_html_no_skeleton = if body_open_index && body_end_index && body_open_index < body_end_index
      cleaned_html_full[(body_open_index + body_open_tag.size)...body_end_index].strip
    else
      ""
    end

    doc.destroy

    BindResult.new(cleaned_html_no_skeleton, bindings)
  end
end
