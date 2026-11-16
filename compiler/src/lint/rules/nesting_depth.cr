require "../diagnostic"
require "../project_index"
require "./complexity"

module Lint::Rules
  # Reports the first AST structure in a method that exceeds the configured
  # nesting limit. Sibling arms such as elsif and when stay at their parent
  # depth, while modifier conditionals and ordinary blocks count as one level.
  module NestingDepth
    RULE        = "metrics/nesting-depth"
    DEFAULT_MAX = 4

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      issues = [] of SourceIssue

      Complexity.each_method(index) do |method|
        body = method.body
        next unless body
        finding = Complexity.first_exceeding(body, max)
        next unless finding

        name = Complexity.method_name(method.node)
        node = finding.node
        issues << SourceIssue.new(
          method.unit.file.relative_path,
          method.unit.map,
          node.start_byte,
          node.end_byte,
          "method '#{name}' reaches nesting depth #{finding.depth}; maximum is #{max}",
          RULE,
          "Extract the nested logic into a helper or a typed child component.",
        )
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end
  end
end
