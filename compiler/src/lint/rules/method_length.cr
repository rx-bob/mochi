require "../diagnostic"
require "../project_index"
require "./complexity"

module Lint::Rules
  # Reports Ruby method bodies over the configured physical line limit.
  # Multiline literals contribute their opening line once; interior and
  # closing lines are ignored so embedded HTML, CSS, and data do not inflate
  # Ruby logic.
  module MethodLength
    RULE        = "metrics/method-length"
    DEFAULT_MAX = 60

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      issues = [] of SourceIssue

      Complexity.each_method(index) do |method|
        count = Complexity.body_line_count(method)
        next if count <= max

        name = Complexity.method_name(method.node)
        issues << SourceIssue.new(
          method.unit.file.relative_path,
          method.unit.map,
          method.node.start_byte,
          method.node.end_byte,
          "method '#{name}' has #{count} body lines; maximum is #{max}",
          RULE,
          "Extract helpers or move embedded data out of the method body.",
        )
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end
  end
end
