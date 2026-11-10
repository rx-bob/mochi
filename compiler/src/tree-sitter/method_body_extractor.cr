require "./ruby_parser"
require "./bindings"
require "../ruby/ruby_def"

module TreeSitter
  class MethodBodyExtractor
    def self.extract_method_bodies(source : String, class_name : String) : Hash(String, RubyDef)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      methods = {} of String => RubyDef

      class_node = find_class_by_name(root, class_name)
      return methods unless class_node

      visit_node_for_methods(class_node, class_name, methods, source)
      return methods
    end

    # Collects the reader names declared with attr_reader / attr_accessor in
    # the component class. Strict bindings treat a bare `{name}` as a method
    # call, and these generated readers count as defined methods.
    def self.extract_attribute_readers(source : String, class_name : String) : Set(String)
      readers = Set(String).new
      parser = RubyParser.new
      tree = parser.parse(source)
      class_node = find_class_by_name(tree.root_node, class_name)
      return readers unless class_node

      body = class_node.child_by_field_name("body")
      return readers unless body

      body.each_named_child do |child|
        method_name = nil
        args_node = nil

        if child.type == "call"
          method_node = child.child_by_field_name("method")
          method_name = method_node.text if method_node
          args_node = child.child_by_field_name("arguments")
        elsif child.type == "command"
          name_node = child.child_by_field_name("name")
          method_name = name_node.text if name_node
          args_node = child.child_by_field_name("arguments")
        end

        next unless method_name
        next unless method_name.in?("attr_reader", "attr_accessor")
        next unless args_node

        args_node.each_named_child do |arg|
          next unless arg.type == "simple_symbol"

          readers << arg.text.lchop(":")
        end
      end

      readers
    end

    # Removes the named instance methods from `class_name` using the exact
    # Tree-sitter byte range of each method node. Line-oriented removal and
    # searching for the literal `end` keyword both fail when an HTML string
    # contains `{end}`, so the parser is the source of truth here.
    def self.remove_methods(source : String, class_name : String, method_names : Array(String)) : String
      return source if method_names.empty?

      parser = RubyParser.new
      tree = parser.parse(source)
      class_node = find_class_by_name(tree.root_node, class_name)
      return source unless class_node

      body = class_node.child_by_field_name("body")
      return source unless body

      ranges = [] of Tuple(Int32, Int32)
      body.each_named_child do |child|
        next unless child.type == "method"

        name_node = child.child_by_field_name("name")
        next unless name_node
        next unless method_names.includes?(name_node.text)

        ranges << {child.start_byte, child.end_byte}
      end
      return source if ranges.empty?

      builder = String::Builder.new
      cursor = 0
      ranges.sort_by! { |range| range[0] }
      ranges.each do |(start_byte, end_byte)|
        next if end_byte <= cursor

        builder << source.byte_slice(cursor, start_byte - cursor) if start_byte > cursor
        cursor = end_byte
      end
      builder << source.byte_slice(cursor, source.bytesize - cursor) if cursor < source.bytesize
      builder.to_s
    end

    private def self.find_class_by_name(node : Node, class_name : String) : Node?
      if node.type == "class"
        if name_node = node.child_by_field_name("name")
          extracted_name = extract_class_name(name_node)
          return node if extracted_name == class_name
        end
      end

      node.each_named_child do |child|
        if result = find_class_by_name(child, class_name)
          return result
        end
      end

      return nil
    end

    private def self.extract_class_name(name_node : Node) : String
      case name_node.type
      when "constant"
        return name_node.text
      when "scope_resolution"
        return extract_scope_resolution(name_node)
      else
        return ""
      end
    end

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

      return parts.join("::")
    end

    private def self.visit_node_for_methods(node : Node, class_name : String, methods : Hash(String, RubyDef), source : String)
      if node.type == "method"
        if ruby_def = extract_method_def(node, class_name, source)
          methods[ruby_def.name.not_nil!] = ruby_def
        end
      end

      node.each_named_child do |child|
        visit_node_for_methods(child, class_name, methods, source)
      end
    end

    private def self.extract_method_def(method_node : Node, class_name : String, source : String) : RubyDef?
      name_node = method_node.child_by_field_name("name")
      return nil unless name_node

      method_name = name_node.text
      parameters = extract_parameters(method_node)
      body = extract_body_as_lines(method_node)

      return RubyDef.new(
        method_name,
        "/todo",
        class_name,
        body,
        parameters
      )
    end

    private def self.extract_parameters(method_node : Node) : Array(String)
      params_node = method_node.child_by_field_name("parameters")
      return [] of String unless params_node

      parameters = [] of String

      params_node.each_named_child do |param|
        case param.type
        when "identifier"
          parameters << param.text
        when "optional_parameter"
          parameters << param.text
        when "splat_parameter"
          parameters << param.text
        when "hash_splat_parameter"
          parameters << param.text
        when "block_parameter"
          parameters << param.text
        when "keyword_parameter"
          parameters << param.text
        else
          parameters << param.text
        end
      end

      return parameters
    end

    private def self.extract_body_as_lines(method_node : Node) : Array(String)
      start_point = LibTreeSitter.ts_node_start_point(method_node.raw)
      end_point = LibTreeSitter.ts_node_end_point(method_node.raw)

      source_lines = method_node.source.lines
      start_row = start_point.row.to_i
      end_row = end_point.row.to_i

      body_lines = [] of String

      (start_row..end_row).each do |row|
        if row < source_lines.size
          body_lines << source_lines[row].chomp
        end
      end

      return body_lines
    end
  end
end
