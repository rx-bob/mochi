require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Counts distinct authored instance methods on a component class. Reopened
  # declarations share one class model, so repeated definitions count once.
  # Attribute readers, prop/event declarations, nested classes, inherited
  # methods, and singleton helpers are not part of the component's instance
  # method surface.
  module ComponentMethods
    RULE        = "metrics/component-methods"
    DEFAULT_MAX = 40

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      locations = {} of String => Tuple(SourceUnit, TreeSitter::ClassDecl)

      index.units.values.sort_by(&.file.relative_path).each do |unit|
        next unless unit.target? && unit.syntax_ok

        unit.declarations.each do |declaration|
          next unless declaration.class?

          info = index.class_info(declaration.qualified_name)
          next unless info && info.component?

          existing = locations[declaration.qualified_name]?
          if existing.nil?
            locations[declaration.qualified_name] = {unit, declaration}
          elsif existing[1].tag_name.nil? && declaration.tag_name
            locations[declaration.qualified_name] = {unit, declaration}
          end
        end
      end

      issues = [] of SourceIssue
      locations.each do |qualified_name, location|
        unit, declaration = location
        info = index.class_info(qualified_name).not_nil!
        count = info.methods.size
        next if count <= max

        issues << SourceIssue.new(
          unit.file.relative_path,
          unit.map,
          declaration.start_byte,
          declaration.end_byte,
          "component '#{info.tag_name}' has #{count} instance methods; maximum is #{max}",
          RULE,
          "Separate responsibilities into typed children or Ruby helpers.",
        )
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end
  end
end
