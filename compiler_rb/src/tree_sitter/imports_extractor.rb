# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "ruby_parser"

module TreeSitter
  class ImportsExtractor
    extend T::Sig

    sig { params(source: String).returns(T::Array[String]) }
    def self.extract_imports(source)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      imports = T.let([], T::Array[String])
      visit_node(root, imports)
      imports
    ensure
      tree&.close
      parser&.close
    end

    sig { params(node: Node, results: T::Array[String]).void }
    private_class_method def self.visit_node(node, results)
      if node.type == "call"
        import = extract_import_from_call(node)
        results << import if import
      end

      node.each_named_child do |child|
        visit_node(child, results)
      end
    end

    sig { params(call_node: Node).returns(T.nilable(String)) }
    private_class_method def self.extract_import_from_call(call_node)
      method_node = call_node.child_by_field_name("method")
      return nil unless method_node

      return nil unless method_node.text == "require"

      arguments_node = call_node.child_by_field_name("arguments")
      return nil unless arguments_node

      arguments_node.each_named_child do |arg|
        if arg.type == "string"
          return extract_string_content(arg)
        end
      end

      nil
    end

    sig { params(string_node: Node).returns(String) }
    private_class_method def self.extract_string_content(string_node)
      string_node.each_named_child do |child|
        if child.type == "string_content"
          return child.text
        end
      end

      text = string_node.text

      if text.start_with?('"') && text.end_with?('"')
        return text[1...-1]
      end

      if text.start_with?("'") && text.end_with?("'")
        return text[1...-1]
      end

      text
    end
  end
end
