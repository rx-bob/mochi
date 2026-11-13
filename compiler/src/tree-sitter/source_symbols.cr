require "./class_extractor"
require "./ruby_parser"

module TreeSitter
  # Symbols owned by one Ruby source file and constant references that can
  # create edges between packages. Exports only include declarations and
  # top-level constant assignments in that source; references ignore string
  # contents and comments.
  record SourceSymbols,
    exports : Array(String),
    references : Array(String),
    method_calls : Array(String)

  class SourceSymbolExtractor
    def self.extract(source : String) : SourceSymbols
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      exports = Set(String).new
      references = Set(String).new
      method_calls = Set(String).new

      collect_exports(root, exports, "")
      collect(root, exports, references, method_calls)

      SourceSymbols.new(exports.to_a.sort, references.to_a.sort, method_calls.to_a.sort)
    end

    private def self.collect_exports(node : Node, exports : Set(String), scope : String) : Nil
      if node.type.in?("class", "module")
        if name = node.child_by_field_name("name")
          scope = qualify(scope, name.text)
          add_constant(exports, scope)
        end
      elsif node.type == "assignment"
        if left = node.child_by_field_name("left")
          add_constant(exports, qualify(scope, left.text)) if left.type.in?("constant", "scope_resolution")
        end
      end
      node.each_named_child { |child| collect_exports(child, exports, scope) }
    end

    private def self.qualify(scope : String, name : String) : String
      return name.lchop("::") if name.starts_with?("::")
      scope.empty? ? name : "#{scope}::#{name}"
    end

    private def self.collect(
      node : Node,
      exports : Set(String),
      references : Set(String),
      method_calls : Set(String),
      scope : String = "",
    ) : Nil
      case node.type
      when "class", "module"
        if name = node.child_by_field_name("name")
          scope = qualify(scope, name.text)
        end
      when "constant"
        local = qualify(scope, node.text)
        add_constant(references, exports.includes?(local) ? local : node.text)
      when "scope_resolution"
        text = node.text
        add_constant(references, text)
        add_constant(references, text.split("::").first)
        return # Children are parts of this reference, not bare exported names.
      when "call"
        if node.child_by_field_name("receiver")
          if method = node.child_by_field_name("method")
            name = method.text
            method_calls << name if name.in?("sum", "min", "max")
          end
        end
      end

      node.each_named_child do |child|
        collect(child, exports, references, method_calls, scope)
      end
    end

    private def self.add_constant(set : Set(String), name : String?) : Nil
      return unless name
      normalized = name.strip
      return if normalized.empty?
      set << normalized
    end
  end
end
