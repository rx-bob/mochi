require "set"

require "../../tree-sitter/ruby_parser"
require "../project_index"

module Lint::Rules
  # Shared AST access for Ruby complexity metrics. Methods are visited in
  # selected source only, and literal contents are never treated as Ruby
  # structure.
  module Complexity
    METHOD_TYPES  = Set{"method", "singleton_method"}
    LITERAL_TYPES = Set{
      "string",
      "chained_string",
      "string_array",
      "symbol_array",
      "bare_string",
      "bare_symbol",
      "regex",
      "subshell",
      "character",
      "heredoc_body",
      "delimited_symbol",
    }

    COUNTED_TYPES = Set{
      "if",
      "unless",
      "case",
      "case_match",
      "while",
      "until",
      "for",
      "rescue",
      "rescue_modifier",
      "if_modifier",
      "unless_modifier",
      "while_modifier",
      "until_modifier",
      "conditional",
      "block",
      "do_block",
    }

    record MethodNode,
      unit : SourceUnit,
      node : TreeSitter::Node,
      body : TreeSitter::Node?

    record LiteralSpan,
      start_row : Int32,
      end_row : Int32

    record DepthFinding,
      node : TreeSitter::Node,
      depth : Int32

    def self.each_method(index : ProjectIndex, &block : MethodNode ->) : Nil
      index.units.values.sort_by(&.file.relative_path).each do |unit|
        next unless unit.target? && unit.syntax_ok
        root = unit.root
        next unless root
        visit_methods(unit, root, &block)
      end
    end

    def self.body_line_count(method : MethodNode) : Int32
      first_row, last_row = body_rows(method)
      return method.body ? 1 : 0 if first_row > last_row

      if body = method.body
        body_start_row = body.start_point.row.to_i
        first_row = body_start_row if body_start_row < first_row && body_start_row <= last_row
      end

      excluded = method.body.try { |body| excluded_rows(body) } || Set(Int32).new
      count = 0
      (first_row..last_row).each do |row|
        count += 1 unless excluded.includes?(row)
      end
      count
    end

    def self.first_exceeding(node : TreeSitter::Node, max : Int32) : DepthFinding?
      first_exceeding(node, max, 0)
    end

    def self.method_name(node : TreeSitter::Node) : String
      node.child_by_field_name("name").try(&.text) || "method"
    end

    private def self.visit_methods(
      unit : SourceUnit,
      node : TreeSitter::Node,
      &block : MethodNode ->
    ) : Nil
      return if LITERAL_TYPES.includes?(node.type)

      if METHOD_TYPES.includes?(node.type)
        yield MethodNode.new(unit, node, node.child_by_field_name("body"))
      end

      node.each_named_child { |child| visit_methods(unit, child, &block) }
    end

    private def self.body_rows(method : MethodNode) : Tuple(Int32, Int32)
      header_row = if parameters = method.node.child_by_field_name("parameters")
                     parameters.end_point.row.to_i
                   else
                     method.node.start_point.row.to_i
                   end
      method_end_row = method.node.end_point.row.to_i
      method.node.each_child do |child|
        method_end_row = child.start_point.row.to_i - 1 if child.type == "end"
      end
      {header_row + 1, method_end_row}
    end

    private def self.excluded_rows(body : TreeSitter::Node) : Set(Int32)
      rows = Set(Int32).new
      collect_literal_spans(body) do |span|
        next if span.end_row <= span.start_row
        ((span.start_row + 1)..span.end_row).each { |row| rows << row }
      end
      rows
    end

    private def self.collect_literal_spans(node : TreeSitter::Node, &block : LiteralSpan ->) : Nil
      if LITERAL_TYPES.includes?(node.type)
        yield LiteralSpan.new(node.start_point.row.to_i, node.end_point.row.to_i)
        return
      end
      node.each_named_child { |child| collect_literal_spans(child, &block) }
    end

    private def self.first_exceeding(node : TreeSitter::Node, max : Int32, depth : Int32) : DepthFinding?
      next_depth = COUNTED_TYPES.includes?(node.type) ? depth + 1 : depth
      return DepthFinding.new(node, next_depth) if next_depth > max
      return nil if LITERAL_TYPES.includes?(node.type)

      node.each_named_child do |child|
        if finding = first_exceeding(child, max, next_depth)
          return finding
        end
      end
      nil
    end
  end
end
