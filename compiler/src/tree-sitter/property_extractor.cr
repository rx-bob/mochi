require "./ruby_parser"

module TreeSitter
  class PropertyExtractor
    struct Property
      property name : String
      property value : String
      property raw_value : String

      def initialize(@name : String, @value : String, @raw_value : String)
      end
    end

    def self.extract_properties(source : String) : Array(Property)
      parser = RubyParser.new
      tree = parser.parse(source)
      extract_properties(tree.root_node)
    end

    def self.extract_properties(root : Node) : Array(Property)
      properties = [] of Property
      visit_node(root, properties, skip_nested: false)
      properties
    end

    # Reads an assignment from a class body without descending into nested
    # classes or modules. A sibling component's metadata must never satisfy a
    # lookup for this component.
    def self.extract_property_from_body(body : Node, property_name : String) : String?
      properties = [] of Property
      visit_node(body, properties, skip_nested: true)
      properties.find { |property| property.name == property_name }.try(&.value)
    end

    def self.extract_property(source : String, property_name : String) : String?
      extract_properties(source).find { |p| p.name == property_name }.try(&.value)
    end

    def self.extract_property(root : Node, property_name : String) : String?
      extract_properties(root).find { |p| p.name == property_name }.try(&.value)
    end

    def self.first_property(source : String) : Property?
      extract_properties(source).first?
    end

    def self.first_property(root : Node) : Property?
      extract_properties(root).first?
    end

    private def self.visit_node(node : Node, results : Array(Property), skip_nested : Bool)
      return if skip_nested && node.type.in?("class", "module")

      if node.type == "assignment"
        if property = extract_property_from_assignment(node)
          results << property
        end
      end

      node.each_named_child do |child|
        visit_node(child, results, skip_nested)
      end
    end

    private def self.extract_property_from_assignment(assignment_node : Node) : Property?
      left_node = assignment_node.child_by_field_name("left")
      return nil unless left_node

      return nil unless left_node.type == "instance_variable"

      property_name = left_node.text

      right_node = assignment_node.child_by_field_name("right")
      return nil unless right_node

      raw_value = right_node.text.strip
      value = extract_value(right_node)

      Property.new(property_name, value, raw_value)
    end

    private def self.extract_value(value_node : Node) : String
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

    private def self.extract_string_content(string_node : Node) : String
      string_node.each_named_child do |child|
        if child.type == "string_content"
          return child.text
        end
      end

      text = string_node.text

      if text.starts_with?("\"") && text.ends_with?("\"")
        return text[1...-1]
      end

      if text.starts_with?("'") && text.ends_with?("'")
        return text[1...-1]
      end

      text
    end

    def self.extract_property_names(source : String) : Array(String)
      properties = extract_properties(source)
      properties.map(&.name)
    end

    def self.extract_properties_hash(source : String) : Hash(String, String)
      properties = extract_properties(source)
      result = {} of String => String
      properties.each do |prop|
        result[prop.name] = prop.value
      end
      result
    end
  end
end
