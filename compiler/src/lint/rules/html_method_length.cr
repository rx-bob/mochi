require "set"

require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Reports component `html` methods that exceed the configured physical line
  # limit. Unlike `metrics/method-length`, embedded template rows count toward
  # the total because the template is the method's main output.
  module HtmlMethodLength
    RULE        = "metrics/html-method-length"
    DEFAULT_MAX = 50

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      components = Set(String).new

      index.units.values.sort_by(&.file.relative_path).each do |unit|
        next unless unit.target? && unit.syntax_ok

        unit.declarations.each do |declaration|
          next unless declaration.class?

          info = index.class_info(declaration.qualified_name)
          components << declaration.qualified_name if info && info.component?
        end
      end

      issues = [] of SourceIssue
      components.each do |qualified_name|
        info = index.class_info(qualified_name).not_nil!
        next unless tag_name = info.tag_name

        info.method_definitions.each do |method|
          next unless method.name == "html" && !method.singleton

          unit = index.unit(method.unit_path)
          next unless unit && unit.target? && unit.syntax_ok

          count = method.node.end_point.row.to_i - method.node.start_point.row.to_i + 1
          next if count <= max

          issues << SourceIssue.new(
            unit.file.relative_path,
            unit.map,
            method.start_byte,
            method.end_byte,
            "component '#{tag_name}' html method has #{count} lines; maximum is #{max}",
            RULE,
            "Split the markup into typed child components or Ruby helpers.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end
  end
end
