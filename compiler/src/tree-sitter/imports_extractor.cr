require "./ruby_parser"

module TreeSitter
  # One literal Ruby require boundary. `line` and `column` are one-based so the
  # dependency graph can report the developer's source location.
  record ImportCall,
    method : String,
    path : String,
    line : Int32,
    column : Int32

  class ImportError < Exception
  end

  class ImportsExtractor
    SUPPORTED_METHODS           = Set{"require", "require_relative"}
    UNSUPPORTED_LOADING_METHODS = Set{"load", "autoload", "require_tree", "require_dependency"}

    def self.extract_imports(source : String) : Array(String)
      extract_import_calls(source).map(&.path)
    end

    def self.extract_imports(root : Node) : Array(String)
      extract_import_calls(root).map(&.path)
    end

    def self.extract_import_calls(source : String, source_path : String = "") : Array(ImportCall)
      parser = RubyParser.new
      tree = parser.parse(source)
      extract_import_calls(tree.root_node, source_path)
    end

    def self.extract_import_calls(root : Node, source_path : String = "") : Array(ImportCall)
      imports = [] of ImportCall
      visit_node(root, imports, source_path)
      imports
    end

    private def self.visit_node(node : Node, results : Array(ImportCall), source_path : String)
      if node.type.in?("call", "command")
        if import = extract_import_from_call(node, source_path)
          results << import
        end
      end

      node.each_named_child do |child|
        visit_node(child, results, source_path)
      end
    end

    private def self.extract_import_from_call(call_node : Node, source_path : String) : ImportCall?
      method_node = call_node.child_by_field_name(call_node.type == "call" ? "method" : "name")
      return nil unless method_node

      method = method_node.text
      if UNSUPPORTED_LOADING_METHODS.includes?(method)
        raise ImportError.new(
          "unsupported Ruby loading expression '#{method}' at #{location(call_node, source_path)}; " \
          "Mochi supports static require and require_relative boundaries"
        )
      end
      return nil unless SUPPORTED_METHODS.includes?(method)

      arguments_node = call_node.child_by_field_name("arguments")
      unless arguments_node
        raise ImportError.new(
          "unsupported dynamic Ruby #{method} at #{location(call_node, source_path)}; " \
          "use one literal string path"
        )
      end

      arguments = [] of Node
      arguments_node.each_named_child { |arg| arguments << arg }
      unless arguments.size == 1 && arguments.first.type == "string"
        raise ImportError.new(
          "unsupported dynamic Ruby #{method} at #{location(call_node, source_path)}; " \
          "use one literal string path"
        )
      end

      string_node = arguments.first
      string_node.each_named_child do |child|
        if child.type == "interpolation"
          raise ImportError.new(
            "unsupported dynamic Ruby #{method} at #{location(call_node, source_path)}; " \
            "interpolated paths cannot be resolved at build time"
          )
        end
      end

      path = extract_string_content(string_node)
      if path.empty?
        raise ImportError.new(
          "unsupported empty Ruby #{method} at #{location(call_node, source_path)}; " \
          "use one literal string path"
        )
      end

      ImportCall.new(
        method,
        path,
        call_node.start_point.row.to_i + 1,
        call_node.start_point.column.to_i + 1
      )
    end

    private def self.location(node : Node, source_path : String) : String
      path = source_path.empty? ? "Ruby source" : source_path
      "#{path}:#{node.start_point.row.to_i + 1}:#{node.start_point.column.to_i + 1}"
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
  end
end
