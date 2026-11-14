require "lexbor"

# The shard binds an unavailable _noi symbol for this exported Lexbor API.
lib Lexbor::Lib
  fun mochi_attribute_qualified_name = lxb_dom_attr_qualified_name(attr : DomAttrT, length : LibC::SizeT*) : UInt8*
end

# Lexbor::Node#attributes exposes local names, which lose SVG casing (viewBox,
# markerWidth, refX). Binding descriptors must use the DOM's qualified names.
module DomAttributes
  def self.read(node : Lexbor::Node) : Hash(String, String)
    result = {} of String => String
    return result if node.tag_name.starts_with?("_")

    attr = Lexbor::Lib.element_first_attribute(node.element)
    until attr.null?
      name = Lexbor::Lib.mochi_attribute_qualified_name(attr, out name_length)
      value = Lexbor::Lib.attribute_value(attr, out value_length)
      result[String.new(name, name_length)] = value.null? ? "" : String.new(value, value_length)
      attr = Lexbor::Lib.element_next_attribute(attr)
    end
    result
  end
end
