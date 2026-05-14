# typed: strict
# frozen_string_literal: true

require_relative "ruby_parser"

module TreeSitter
  class ClassExtractor
    extend T::Sig

    sig { params(source: String).returns(T::Array[String]) }
    def self.extract_class_names(source)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      class_names = T.let([], T::Array[String])
      visit_node(root, class_names)
      class_names
    ensure
      tree&.close
      parser&.close
    end

    sig { params(source: String).returns(String) }
    def self.class_name(source)
      names = extract_class_names(source)
      names.first || ""
    end

    sig { params(source: String).returns(T.nilable(String)) }
    def self.extract_superclass(source)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      class_node = find_first_class(root)
      return nil unless class_node

      superclass_node = class_node.child_by_field_name("superclass")
      return nil unless superclass_node

      superclass_node.text.strip
    ensure
      tree&.close
      parser&.close
    end

    sig { params(node: Node, results: T::Array[String]).void }
    def self.visit_node(node, results)
      if node.type == "class"
        class_name = extract_class_name_from_node(node)
        results << class_name if class_name
      end

      node.each_named_child do |child|
        visit_node(child, results)
      end
    end

    sig { params(class_node: Node).returns(T.nilable(String)) }
    def self.extract_class_name_from_node(class_node)
      name_node = class_node.child_by_field_name("name")
      return nil unless name_node

      case name_node.type
      when "constant"
        name_node.text
      when "scope_resolution"
        extract_scope_resolution(name_node)
      else
        nil
      end
    end

    sig { params(node: Node).returns(String) }
    def self.extract_scope_resolution(node)
      parts = T.let([], T::Array[String])

      if scope = node.child_by_field_name("scope")
        case scope.type
        when "constant"
          parts << scope.text
        when "scope_resolution"
          parts << extract_scope_resolution(scope)
        end
      end

      if name = node.child_by_field_name("name")
        parts << name.text
      end

      parts.join("::")
    end

    sig { params(node: Node).returns(T.nilable(Node)) }
    def self.find_first_class(node)
      return node if node.type == "class"

      node.each_named_child do |child|
        result = find_first_class(child)
        return result if result
      end

      nil
    end
  end
end
