require "./ruby_parser"
require "./class_decl"
require "./property_extractor"

module TreeSitter
  class ClassExtractor
    def self.extract_class_names(source : String) : Array(String)
      parser = RubyParser.new
      tree = parser.parse(source)
      extract_class_names(tree.root_node)
    end

    def self.extract_class_names(root : Node) : Array(String)
      extract_class_decls(root).select(&.class?).map(&.name)
    end

    def self.class_name(source : String) : String
      names = extract_class_names(source)
      names.first? || ""
    end

    def self.class_name(root : Node) : String
      names = extract_class_names(root)
      names.first? || ""
    end

    # Returns every class and module declaration in source order. Class
    # metadata is scoped to the declaration body so sibling classes cannot
    # contribute tags, methods, or attribute readers.
    def self.extract_class_decls(root : Node) : Array(ClassDecl)
      declarations = [] of ClassDecl
      enclosing = [] of Node
      visit_declarations(root, enclosing, declarations)
      declarations
    end

    # Extracts a class/module's syntax name, e.g. `A::B` for
    # `class A::B` or `B` for `class B` nested inside `module A`.
    def self.declaration_name(node : Node) : String?
      name_node = node.child_by_field_name("name")
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

    # Extract superclass if present
    def self.extract_superclass(source : String) : String?
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      class_node = find_first_class(root)
      return nil unless class_node

      superclass_node = class_node.child_by_field_name("superclass")
      return nil unless superclass_node

      constant_name(superclass_node)
    end

    # Extracts the syntax name of a class or module constant without the
    # `"< "` prefix Tree-sitter includes on the `superclass` wrapper node.
    def self.constant_name(node : Node) : String?
      case node.type
      when "constant", "scope_resolution"
        node.text.lchop("::")
      when "superclass"
        node.each_named_child do |child|
          if name = constant_name(child)
            return name
          end
        end
        nil
      else
        nil
      end
    end

    private def self.visit_declarations(node : Node, enclosing : Array(Node), results : Array(ClassDecl))
      if node.type.in?("class", "module")
        if name = declaration_name(node)
          body = node.child_by_field_name("body")
          method_names, readers = collect_body_metadata(body)
          tag_name = body ? PropertyExtractor.extract_property_from_body(body, "@tag_name") : nil
          wrapper_start = enclosing.first?.try(&.start_byte) || node.start_byte
          wrapper_end = enclosing.first?.try(&.end_byte) || node.end_byte

          results << ClassDecl.new(
            node,
            name,
            node.type,
            node.start_byte,
            node.end_byte,
            node.start_point.row.to_i + 1,
            enclosing.compact_map { |parent| declaration_name(parent) },
            wrapper_start,
            wrapper_end,
            tag_name,
            method_names,
            readers
          )
        end
      end

      enclosing << node if node.type.in?("class", "module")
      node.each_named_child do |child|
        visit_declarations(child, enclosing, results)
      end
      enclosing.pop if node.type.in?("class", "module")
    end

    private def self.collect_body_metadata(body : Node?) : Tuple(Array(String), Set(String))
      method_names = [] of String
      readers = Set(String).new
      return {method_names, readers} unless body

      body.each_named_child do |child|
        if child.type == "method"
          if name_node = child.child_by_field_name("name")
            method_names << name_node.text
          end
          next
        end

        next unless child.type.in?("call", "command")

        method_node = child.child_by_field_name(child.type == "call" ? "method" : "name")
        next unless method_node
        next unless method_node.text.in?("attr_reader", "attr_accessor")

        args_node = child.child_by_field_name("arguments")
        next unless args_node

        args_node.each_named_child do |arg|
          next unless arg.type == "simple_symbol"

          readers << arg.text.lchop(":")
        end
      end

      {method_names, readers}
    end

    # Extract full name from scope_resolution node (e.g., "A::B::C")
    private def self.extract_scope_resolution(node : Node) : String
      parts = [] of String

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

    private def self.find_first_class(node : Node) : Node?
      return node if node.type == "class"

      node.each_named_child do |child|
        if result = find_first_class(child)
          return result
        end
      end

      nil
    end
  end
end
