require "set"

require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Declared props are read-only snapshots installed by the loader. This rule
  # reports direct writes in authored instance methods and two-way form
  # bindings. It never chases aliases or arbitrary methods: only the prop
  # instance variable itself, an indexed target rooted at it, and recognized
  # collection/string mutators count.
  module PropWrites
    PROP_WRITE = "components/prop-write"

    BIND_ATTRIBUTES = Set{"bind:value", "bind:checked"}

    DIRECT_MUTATORS = Set{
      "<<", "[]=", "append", "clear", "compare_by_identity", "concat",
      "default=", "delete", "delete_at", "delete_if", "fill", "filter!",
      "force_encoding", "insert", "keep_if", "merge!", "pop", "prepend",
      "push", "rehash", "reject!", "replace", "select!", "shift", "slice!",
      "store", "unshift", "update",
    }

    record WriteTarget, node : TreeSitter::Node, prop : String

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(PROP_WRITE)

      issues = method_issues(index) + binding_issues(index)
      diagnostics = issues.compact_map do |issue|
        severity = index.config.severity_for(issue.rule)
        severity ? issue.diagnostic(severity) : nil
      end
      Diagnostics.sort(diagnostics)
    end

    private def self.method_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue

      index.classes.each_value do |info|
        next unless info.component?
        next if info.props.empty?
        props = info.props.map(&.name).to_set

        info.method_definitions.each do |method|
          next if method.singleton
          next unless index.selected.includes?(method.unit_path)
          body = method.body
          unit = index.unit(method.unit_path)
          next unless body && unit

          visit_writes(unit, method.name, body, props, issues)
        end
      end

      issues
    end

    private def self.visit_writes(
      unit : SourceUnit,
      method_name : String,
      node : TreeSitter::Node,
      props : Set(String),
      issues : Array(SourceIssue),
    ) : Nil
      return if node.type.in?("method", "singleton_method", "singleton_class", "class", "module")

      if node.type.in?("assignment", "operator_assignment", "multiple_assignment")
        if left = node.child_by_field_name("left")
          prop_targets(left, props).each do |target|
            issues << write_issue(unit, method_name, target.node, target.prop)
          end
        end
      elsif node.type == "binary"
        left = node.child_by_field_name("left")
        operator = node.child(1)
        if left && operator.type == "<<"
          if prop = prop_base_name(left, props)
            issues << write_issue(unit, method_name, node, prop)
          end
        end
      elsif node.type == "call"
        receiver = node.child_by_field_name("receiver")
        method = node.child_by_field_name("method")
        if receiver && method && receiver.type == "instance_variable" &&
           (prop = prop_base_name(receiver, props)) &&
           direct_mutator?(method.text)
          issues << write_issue(unit, method_name, node, prop)
        end
      end

      node.each_named_child do |child|
        visit_writes(unit, method_name, child, props, issues)
      end
    end

    private def self.prop_targets(node : TreeSitter::Node, props : Set(String)) : Array(WriteTarget)
      case node.type
      when "instance_variable"
        if prop = prop_base_name(node, props)
          [WriteTarget.new(node, prop)]
        else
          [] of WriteTarget
        end
      when "element_reference"
        if prop = prop_base_name(node, props)
          [WriteTarget.new(node, prop)]
        else
          [] of WriteTarget
        end
      when "left_assignment_list", "destructured_left_assignment", "rest_assignment"
        targets = [] of WriteTarget
        node.each_named_child do |child|
          targets.concat(prop_targets(child, props))
        end
        targets
      else
        [] of WriteTarget
      end
    end

    private def self.prop_base_name(node : TreeSitter::Node, props : Set(String)) : String?
      case node.type
      when "instance_variable"
        name = node.text.lchop('@')
        props.includes?(name) ? name : nil
      when "element_reference"
        first = first_named_child(node)
        first ? prop_base_name(first, props) : nil
      end
    end

    private def self.direct_mutator?(name : String) : Bool
      DIRECT_MUTATORS.includes?(name) || name.ends_with?('!')
    end

    private def self.first_named_child(node : TreeSitter::Node) : TreeSitter::Node?
      return nil if node.named_child_count == 0
      node.named_child(0)
    end

    private def self.write_issue(
      unit : SourceUnit,
      method_name : String,
      node : TreeSitter::Node,
      prop : String,
    ) : SourceIssue
      suggestion = if method_name == "initialize"
                     "move derived state to a separate ivar; constructor assignments to '@#{prop}' " \
                     "are overwritten when the declared prop is installed"
                   else
                     "keep '@#{prop}' read-only and store edits in a separate ivar, " \
                     "or emit a child event so the parent changes the input"
                   end

      SourceIssue.new(
        unit.file.relative_path,
        unit.map,
        node.start_byte,
        node.end_byte,
        "declared prop '@#{prop}' is written in '#{method_name}'; declared props are read-only input snapshots",
        PROP_WRITE,
        suggestion,
      )
    end

    private def self.binding_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue

      index.target_templates.each do |view|
        owner = index.class_info(view.owner_name)
        next unless owner
        next if owner.props.empty?
        props = owner.props.map(&.name).to_set

        view.attributes.each do |attribute|
          next unless BIND_ATTRIBUTES.includes?(attribute.name.downcase)
          prop = binding_prop_name(attribute.value(view.text))
          next unless prop && props.includes?(prop)

          range = view.source_range(attribute.start, attribute.finish)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "two-way binding '#{attribute.name}' writes declared prop '@#{prop}'; " \
            "declared props are read-only input snapshots",
            PROP_WRITE,
            "bind a separate local state ivar instead of '@#{prop}', " \
            "or emit a child event so the parent changes the input",
          )
        end
      end

      issues
    end

    private def self.binding_prop_name(value : String) : String?
      text = value.strip
      if match = text.match(/\A@([a-zA-Z_][a-zA-Z0-9_]*)\z/)
        match[1]
      elsif match = text.match(/\A\{\s*@([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\z/)
        match[1]
      end
    end
  end
end
