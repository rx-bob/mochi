require "./class_extractor"
require "./ruby_parser"

module TreeSitter
  # Symbols owned by one Ruby source file and constant references that can
  # create edges between packages. Exports only include declarations and
  # top-level constant assignments in that source; references ignore string
  # contents and comments.
  record SourceSymbols,
    exports : Array(String),
    references : Array(String)

  class SourceSymbolExtractor
    def self.extract(source : String) : SourceSymbols
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      exports = Set(String).new
      references = Set(String).new

      collect_declaration_exports(root, exports)
      collect(root, exports, references)

      SourceSymbols.new(exports.to_a.sort, references.to_a.sort)
    end

    private def self.collect_declaration_exports(root : Node, exports : Set(String)) : Nil
      ClassExtractor.extract_class_decls(root).each do |declaration|
        add_constant(exports, declaration.name)
        add_constant(exports, declaration.qualified_name)
        add_constant(exports, declaration.enclosing.first?) if declaration.enclosing.first?
      end
    end

    private def self.collect(node : Node, exports : Set(String), references : Set(String)) : Nil
      case node.type
      when "constant"
        add_constant(references, node.text)
      when "scope_resolution"
        text = node.text
        add_constant(references, text)
        add_constant(references, text.split("::").first)
      when "assignment"
        if left = node.child_by_field_name("left")
          if left.type.in?("constant", "scope_resolution")
            text = left.text
            add_constant(exports, text)
            add_constant(exports, text.split("::").first)
          end
        end
      end

      node.each_named_child do |child|
        collect(child, exports, references)
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
