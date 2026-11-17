require "set"

require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Counts authored component state. Class-body `@name` declarations count, and
  # assignments to instance variables inside `initialize`, `mounted`, or
  # `unmounted` count too, so moving setup into a lifecycle method does not hide
  # it. The framework `@tag_name`, declared props, and nested classes are
  # outside the state budget.
  module ClassVariables
    RULE         = "metrics/class-variables"
    DEFAULT_MAX  = 10
    RESERVED     = Set{"tag_name"}
    LIFECYCLE    = Set{"initialize", "mounted", "unmounted"}
    NESTED       = Set{"method", "singleton_method", "singleton_class", "class", "module"}
    ASSIGNMENTS  = Set{"assignment", "operator_assignment", "multiple_assignment"}
    TARGET_LISTS = Set{"left_assignment_list", "destructured_left_assignment", "rest_assignment"}

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
        props = info.props.map(&.name).to_set
        info.declarations.each do |class_declaration|
          collect_class_variables(class_declaration.node.child_by_field_name("body"), names, props)
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

    private def self.collect_class_variables(node : TreeSitter::Node?, names : Set(String), props : Set(String)) : Nil
      return unless node

      if node.type == "method"
        name = node.child_by_field_name("name").try(&.text)
        if name && LIFECYCLE.includes?(name)
          collect_method_assignments(node.child_by_field_name("body"), names, props)
        end
        return
      end
      return if NESTED.includes?(node.type)

      if node.type == "instance_variable"
        add_name(node, names, props)
      end

      node.each_named_child { |child| collect_class_variables(child, names, props) }
    end

    private def self.collect_method_assignments(node : TreeSitter::Node?, names : Set(String), props : Set(String)) : Nil
      return unless node
      return if NESTED.includes?(node.type)

      if ASSIGNMENTS.includes?(node.type)
        if left = node.child_by_field_name("left")
          collect_assignment_targets(left, names, props)
        end
      end

      node.each_named_child { |child| collect_method_assignments(child, names, props) }
    end

    private def self.collect_assignment_targets(node : TreeSitter::Node, names : Set(String), props : Set(String)) : Nil
      if node.type == "instance_variable"
        add_name(node, names, props)
      elsif TARGET_LISTS.includes?(node.type)
        node.each_named_child { |child| collect_assignment_targets(child, names, props) }
      end
    end

    private def self.add_name(node : TreeSitter::Node, names : Set(String), props : Set(String)) : Nil
      name = node.text.lchop('@')
      names << name unless RESERVED.includes?(name) || props.includes?(name)
    end
  end
end
