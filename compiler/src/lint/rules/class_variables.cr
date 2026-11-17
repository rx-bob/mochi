require "set"

require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Counts authored class-body instance variable declarations on a component.
  # The framework `@tag_name` declaration and variables used only inside
  # methods or nested classes are not part of this state budget.
  module ClassVariables
    RULE        = "metrics/class-variables"
    DEFAULT_MAX = 10
    RESERVED    = Set{"tag_name"}
    SKIPPED     = Set{"method", "singleton_method", "singleton_class", "class", "module"}

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
        names = Set(String).new
        info.declarations.each do |class_declaration|
          collect_class_variables(class_declaration.node.child_by_field_name("body"), names)
        end
        count = names.size
        next if count <= max

        issues << SourceIssue.new(
          unit.file.relative_path,
          unit.map,
          declaration.start_byte,
          declaration.end_byte,
          "component '#{info.tag_name}' declares #{count} class variables; maximum is #{max}",
          RULE,
          "Group related state into a plain Ruby object or typed child components.",
        )
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.collect_class_variables(node : TreeSitter::Node?, names : Set(String)) : Nil
      return unless node
      return if SKIPPED.includes?(node.type)

      if node.type == "instance_variable"
        name = node.text.lchop('@')
        names << name unless RESERVED.includes?(name)
      end

      node.each_named_child { |child| collect_class_variables(child, names) }
    end
  end
end
