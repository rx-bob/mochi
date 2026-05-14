# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "ruby_parser"

module TreeSitter
  class PropertyExtractor
    extend T::Sig

    class Property < T::Struct
      const :name, String
      const :value, String
      const :raw_value, String
    end

    sig { params(source: String).returns(T::Array[Property]) }
    def self.extract_properties(source)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      properties = T.let([], T::Array[Property])
      visit_node(root, properties)
      properties
    ensure
      tree&.close
      parser&.close
    end

    sig { params(source: String, property_name: String).returns(T.nilable(String)) }
    def self.extract_property(source, property_name)
      properties = extract_properties(source)
      property = properties.find { |p| p.name == property_name }
      property&.value
    end

    sig { params(source: String).returns(T.nilable(Property)) }
    def self.first_property(source)
      properties = extract_properties(source)
      properties.first
    end

    sig { params(node: Node, results: T::Array[Property]).void }
    private_class_method def self.visit_node(node, results)
      if node.type == "assignment"
        property = extract_property_from_assignment(node)
        results << property if property
      end

      node.each_named_child do |child|
        visit_node(child, results)
      end
    end

    sig { params(assignment_node: Node).returns(T.nilable(Property)) }
    private_class_method def self.extract_property_from_assignment(assignment_node)
      left_node = assignment_node.child_by_field_name("left")
      return nil unless left_node

      return nil unless left_node.type == "instance_variable"

      property_name = left_node.text

      right_node = assignment_node.child_by_field_name("right")
      return nil unless right_node

      raw_value = right_node.text.strip
      value = extract_value(right_node)

      Property.new(name: property_name, value: value, raw_value: raw_value)
    end

    sig { params(value_node: Node).returns(String) }
    private_class_method def self.extract_value(value_node)
      case value_node.type
      when "string"
        extract_string_content(value_node)
      when "integer", "float"
        value_node.text
      when "true", "false", "nil"
        value_node.text
      when "constant", "identifier"
        value_node.text
      when "symbol"
        value_node.text
      else
        value_node.text
      end
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

    sig { params(source: String).returns(T::Array[String]) }
    def self.extract_property_names(source)
      properties = extract_properties(source)
      properties.map(&:name)
    end

    sig { params(source: String).returns(T::Hash[String, String]) }
    def self.extract_properties_hash(source)
      properties = extract_properties(source)
      result = T.let({}, T::Hash[String, String])
      properties.each do |prop|
        result[prop.name] = prop.value
      end
      result
    end
  end
end
