# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../lexbor/bindings"

class ComponentGenerator
  extend T::Sig

  class Binding < T::Struct
    const :path, T::Array[Integer]
    const :type, Symbol # :text, :html, :attr, :anchor
    const :value, String
    const :name, T.nilable(String) # attribute name for :attr type

    def self.new(path:, type:, value:, name: nil)
      super
    end
  end

  sig { void }
  def initialize
  end

  # Walk the Lexbor DOM tree and build a list of Binding objects.
  # Text nodes, comment nodes (anchors), and element attributes are scanned
  # for reactive patterns.  Attributes that start with "bind:" are handled
  # specially (the prefix is stripped and the attribute is removed from the
  # DOM).  Children are recursed into with path indices that reflect ALL
  # childNodes (text, comment, element) so that runtime childNode access matches.
  sig do
    params(
      node: Lexbor::Node,
      path: T::Array[Integer],
      bindings: T::Array[Binding]
    ).void
  end
  def traverse(node, path, bindings)
    tag = node.tag_name

    if tag == "_text"
      text = node.tag_text
      if text =~ /\{([^}]+)\}/
        var_name = $1
        # Pure variable nodes (e.g. "\n  {rendered_svg}\n") use innerHTML to allow HTML/SVG content
        binding_type = text.strip == "{#{var_name}}" ? :html : :text
        bindings << Binding.new(path: path, type: binding_type, value: "{#{var_name}}")
      end
    elsif tag == "_em_comment"
      text = node.tag_text
      if text && (text.include?("if-anchor") || text.include?("each-anchor"))
        bindings << Binding.new(path: path, type: :anchor, value: text)
      end
    else
      attrs = node.attributes
      if attrs
        remove_attrs = []
        attrs.each do |k, v|
          if k.start_with?("bind:")
            attr_name = k[5..]
            var_name = v.gsub(/[{}]/, "")
            bindings << Binding.new(path: path, type: :attr, value: "{#{var_name}}", name: attr_name)
            remove_attrs << k
          elsif k.start_with?("on")
            # Event handler attribute — leave in HTML for event delegation, don't treat as reactive binding
          elsif v =~ /\{([^}]+)\}/
            var_name = $1
            bindings << Binding.new(path: path, type: :attr, value: "{#{var_name}}", name: k)
            remove_attrs << k
          end
        end
        remove_attrs.each { |k| node.attribute_remove(k) }
      end

      children = node.children
      if children
        children.each_with_index do |child, i|
          traverse(child, path + [i], bindings)
        end
      end
    end
  end
end
