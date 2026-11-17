require "set"

require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Rejects dynamic method dispatch hooks on components. A template handler or
  # binding must resolve to an explicit method, not a catch-all dispatcher.
  module MethodMissing
    RULE  = "correctness/method-missing"
    NAMES = Set{"method_missing", "respond_to_missing?"}

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      index.classes.each_value do |info|
        next unless info.component?

        info.method_definitions.each do |method|
          next if method.singleton
          next unless NAMES.includes?(method.name)
          next unless index.selected.includes?(method.unit_path)

          unit = index.unit(method.unit_path)
          next unless unit && unit.syntax_ok

          issues << SourceIssue.new(
            unit.file.relative_path,
            unit.map,
            method.start_byte,
            method.end_byte,
            "component '#{info.tag_name}' defines '#{method.name}', which can bypass template method checks",
            RULE,
            "Define each delegated method explicitly or call a named Ruby helper.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end
  end
end
