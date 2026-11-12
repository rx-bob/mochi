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

    # One `prop :name, Type` declaration from a component class body.
    # `default_code` is the Ruby source of the default expression so the
    # generated mount method can evaluate it in the component's context.
    struct PropDeclaration
      property name : String
      property type : String
      property type_name : String
      property required : Bool
      property default_code : String?
      property line : Int32
      property column : Int32

      def initialize(
        @name : String,
        @type : String,
        @type_name : String,
        @required : Bool,
        @default_code : String?,
        @line : Int32,
        @column : Int32,
      )
      end

      def has_default? : Bool
        !@default_code.nil?
      end
    end

    PROP_TYPES = {
      "String"  => "string",
      "Integer" => "integer",
      "Boolean" => "boolean",
      "Array"   => "array",
      "Hash"    => "hash",
    }

    class PropDeclarationError < Exception
      getter line : Int32

      def initialize(message : String, @line : Int32)
        super(message)
      end
    end

    # Reads direct `prop` declarations from the outermost class body. Nested
    # classes and method bodies are ignored so a sibling component cannot
    # contribute a schema.
    def self.extract_props(source : String, file : String = "") : Array(PropDeclaration)
      parser = RubyParser.new
      tree = parser.parse(source)
      declarations = [] of PropDeclaration
      visit_props(tree.root_node, declarations, file)
      declarations
    end

    def self.extract_props_from_class(class_node : Node, file : String = "") : Array(PropDeclaration)
      body = class_node.child_by_field_name("body")
      return [] of PropDeclaration unless body

      declarations = [] of PropDeclaration
      body.each_named_child do |child|
        if declaration = prop_declaration(child, file)
          declarations << declaration
        end
      end
      validate_props(declarations)
      declarations
    end

    private def self.visit_props(node : Node, declarations : Array(PropDeclaration), file : String) : Nil
      if node.type == "class"
        declarations.concat(extract_props_from_class(node, file))
        return
      end

      node.each_named_child do |child|
        visit_props(child, declarations, file)
      end
    end

    private def self.prop_declaration(node : Node, file : String) : PropDeclaration?
      return nil unless node.type == "call" || node.type == "command"

      return nil if node.child_by_field_name("receiver")
      method = node.child_by_field_name("method")
      return nil unless method && method.text == "prop"

      arguments = node.child_by_field_name("arguments")
      return nil unless arguments

      names = [] of Node
      arguments.each_named_child do |argument|
        names << argument
      end
      return nil if names.empty?

      line = node.start_point.row.to_i + 1
      column = node.start_point.column.to_i + 1
      location = file.empty? ? "line #{line}" : "#{file}:#{line}"

      name_node = names[0]
      unless name_node.type == "simple_symbol" || name_node.type == "delimited_symbol"
        raise PropDeclarationError.new("prop name must be a symbol, got #{name_node.text}", line)
      end
      name = name_node.text.lchop(':').strip('"')
      unless name.matches?(/\A[a-z_][a-z0-9_]*\z/)
        raise PropDeclarationError.new("invalid prop name #{name_node.text} at #{location}; use lower_snake_case", line)
      end

      if names.size < 2
        raise PropDeclarationError.new("prop :#{name} at #{location} is missing a type", line)
      end
      type_node = names[1]
      unless type_node.type == "constant"
        raise PropDeclarationError.new("prop :#{name} at #{location} must declare String, Integer, Boolean, Array, or Hash", line)
      end
      type_name = type_node.text
      type = PROP_TYPES[type_name]?
      unless type
        raise PropDeclarationError.new("prop :#{name} at #{location} uses unsupported type #{type_name}", line)
      end

      required = false
      default_code : String? = nil
      names[2..].each do |option|
        unless option.type == "pair"
          raise PropDeclarationError.new("prop :#{name} at #{location} has an unexpected argument #{option.text}", line)
        end

        key_node = option.child_by_field_name("key")
        value_node = option.child_by_field_name("value")
        unless key_node && value_node
          raise PropDeclarationError.new("prop :#{name} at #{location} has an invalid option", line)
        end

        key = key_node.text.lchop(':')
        case key
        when "required"
          unless value_node.type == "true" || value_node.type == "false"
            raise PropDeclarationError.new("prop :#{name} at #{location} required: must be true or false", line)
          end
          if required
            raise PropDeclarationError.new("prop :#{name} at #{location} declares required: more than once", line)
          end
          required = value_node.type == "true"
        when "default"
          if default_code
            raise PropDeclarationError.new("prop :#{name} at #{location} declares default: more than once", line)
          end
          default_code = value_node.text
          validate_default(name, type, value_node, location, line)
        else
          raise PropDeclarationError.new("prop :#{name} at #{location} has unknown option #{key}:", line)
        end
      end

      if required && default_code
        raise PropDeclarationError.new("prop :#{name} at #{location} cannot be required and declare a default", line)
      end

      PropDeclaration.new(name, type, type_name, required, default_code, line, column)
    end

    private def self.validate_default(
      name : String,
      type : String,
      value_node : Node,
      location : String,
      line : Int32,
    ) : Nil
      return if value_node.type == "nil" || value_node.type == "constant"

      allowed = case type
                when "string"
                  value_node.type == "string"
                when "integer"
                  value_node.type == "integer" || (value_node.type == "unary" && value_node.text.matches?(/\A-\d+\z/))
                when "boolean"
                  value_node.type == "true" || value_node.type == "false"
                when "array"
                  value_node.type == "array"
                when "hash"
                  value_node.type == "hash"
                else
                  false
                end

      return if allowed
      raise PropDeclarationError.new(
        "prop :#{name} at #{location} default #{value_node.text} does not match #{type}",
        line
      )
    end

    private def self.validate_props(declarations : Array(PropDeclaration)) : Nil
      seen = {} of String => Int32
      declarations.each do |declaration|
        if first = seen[declaration.name]?
          raise PropDeclarationError.new(
            "prop :#{declaration.name} is declared twice (first at line #{first})",
            declaration.line
          )
        end
        seen[declaration.name] = declaration.line
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
