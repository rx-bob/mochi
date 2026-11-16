require "../../html/template_expression"
require "../../tree-sitter/ruby_parser"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Opt-in migration advice for currency calls that round scaled major units
  # immediately before formatting. The detector is deliberately narrow: it
  # examines only the first argument of a direct MochiFormat.currency call and
  # recognizes a multiplication followed by `round` and/or `to_i`. It does not
  # infer money from names, inspect Float arithmetic elsewhere, or prove that
  # the resulting total is wrong. The finding is a review prompt for moving
  # accumulation into exact minor-unit ledgers.
  module MoneyAdvice
    RULE = "money/float-to-minor-units"

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(RULE)
      severity = index.config.severity_for(RULE)
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      index.units.values.sort_by(&.file.relative_path).each do |unit|
        next unless unit.target? && unit.syntax_ok
        root = unit.root
        next unless root

        visit_currency_calls(root) do |conversion|
          issues << issue(unit, conversion)
        end
      end

      parser = TreeSitter::RubyParser.new
      begin
        index.target_templates.each do |view|
          visit_template_expressions(view, parser, issues)
        end
      ensure
        parser.close
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.visit_currency_calls(
      node : TreeSitter::Node,
      &block : TreeSitter::Node ->
    ) : Nil
      if currency_call?(node) && (conversion = first_argument(node))
        yield conversion if direct_conversion?(conversion)
      end

      node.each_named_child { |child| visit_currency_calls(child, &block) }
    end

    private def self.visit_template_expressions(
      view : TemplateView,
      parser : TreeSitter::RubyParser,
      issues : Array(SourceIssue),
    ) : Nil
      view.expressions.each do |expression|
        tree = parser.parse(expression.source)
        begin
          root = tree.root_node
          next if root.has_error?

          inner_start = template_inner_start(view, expression)
          visit_currency_calls(root) do |conversion|
            range = view.source_range(
              inner_start + conversion.start_byte,
              inner_start + conversion.end_byte,
            )
            issues << issue(view.unit_path, view.map, range.start_byte, range.end_byte)
          end
        ensure
          tree.close
        end
      end
    end

    private def self.template_inner_start(view : TemplateView, expression : TemplateExpression) : Int32
      index = expression.template_start + 1
      while index < expression.template_end && TemplateExpressionParser.whitespace?(view.text.byte_at(index))
        index += 1
      end
      index
    end

    private def self.issue(unit : SourceUnit, conversion : TreeSitter::Node) : SourceIssue
      issue(unit.file.relative_path, unit.map, conversion.start_byte, conversion.end_byte)
    end

    private def self.issue(path : String, map : SourceMap, start_byte : Int32, end_byte : Int32) : SourceIssue
      SourceIssue.new(
        path,
        map,
        start_byte,
        end_byte,
        "MochiFormat.currency receives rounded scaled major units; use MochiMoney to accumulate exact minor units and a named round_* mode once at display; this is a review prompt, not proof that the total is wrong",
        RULE,
        "Accumulate exact minor units in MochiMoney, apply one named round_* mode at the display boundary, then pass the Integer to MochiFormat.currency.",
      )
    end

    private def self.currency_call?(node : TreeSitter::Node) : Bool
      return false unless node.type == "call"
      receiver = node.child_by_field_name("receiver")
      method = node.child_by_field_name("method")
      return false unless receiver && method
      receiver.type == "constant" &&
        receiver.text.lchop("::") == "MochiFormat" &&
        method.text == "currency"
    end

    private def self.first_argument(call : TreeSitter::Node) : TreeSitter::Node?
      arguments = call.child_by_field_name("arguments")
      return nil unless arguments && arguments.named_child_count > 0
      arguments.named_child(0)
    end

    private def self.direct_conversion?(node : TreeSitter::Node) : Bool
      current = unwrap(node)
      saw_to_i = false

      while current.type == "call" && method_name(current) == "to_i"
        receiver = current.child_by_field_name("receiver")
        break unless receiver
        saw_to_i = true
        current = unwrap(receiver)
      end

      return true if rounded_multiply?(current)
      saw_to_i && multiplied?(current)
    end

    private def self.rounded_multiply?(node : TreeSitter::Node) : Bool
      return false unless node.type == "call" && method_name(node) == "round"
      return false unless zero_precision_round?(node)

      receiver = node.child_by_field_name("receiver")
      return false unless receiver
      multiplied?(unwrap(receiver))
    end

    private def self.zero_precision_round?(call : TreeSitter::Node) : Bool
      arguments = call.child_by_field_name("arguments")
      return true unless arguments

      children = [] of TreeSitter::Node
      arguments.each_named_child { |child| children << child }
      return true if children.empty?
      children.size == 1 && integer_zero?(children.first)
    end

    private def self.integer_zero?(node : TreeSitter::Node) : Bool
      return false unless node.type == "integer"
      node.text.delete('_') == "0"
    end

    private def self.multiplied?(node : TreeSitter::Node) : Bool
      return false unless node.type == "binary"
      left = node.child_by_field_name("left")
      right = node.child_by_field_name("right")
      operator = node.child(1)
      !!left && !!right && operator.type == "*"
    end

    private def self.method_name(node : TreeSitter::Node) : String?
      node.child_by_field_name("method").try(&.text)
    end

    private def self.unwrap(node : TreeSitter::Node) : TreeSitter::Node
      current = node
      while current.type == "parenthesized_statements" && current.named_child_count == 1
        current = current.named_child(0)
      end
      current
    end
  end
end
