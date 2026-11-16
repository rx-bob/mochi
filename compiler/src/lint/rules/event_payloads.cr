require "big"
require "set"

require "../../tree-sitter/string_extractor"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Checks literal child-event emissions against declared event schemas and
  # validates `on:<event>` connections to known child components. Dynamic
  # event names, dynamic payloads, and hash splats remain statically unknown.
  module EventPayloads
    EVENT_PAYLOAD = "correctness/event-payload"

    record PayloadEntry, key_node : TreeSitter::Node, value_node : TreeSitter::Node

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(EVENT_PAYLOAD)

      issues = emit_issues(index) + subscription_issues(index)
      diagnostics = issues.compact_map do |issue|
        severity = index.config.severity_for(issue.rule)
        severity ? issue.diagnostic(severity) : nil
      end
      Diagnostics.sort(diagnostics)
    end

    private def self.emit_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue

      index.classes.each_value do |info|
        next unless info.component?
        next if info.events.empty?
        declarations = {} of String => TreeSitter::PropertyExtractor::EventDeclaration
        info.events.each { |event| declarations[event.name] = event }

        info.method_definitions.each do |method|
          next if method.singleton
          next unless index.selected.includes?(method.unit_path)
          body = method.body
          unit = index.unit(method.unit_path)
          next unless body && unit

          visit_emits(info, declarations, unit, body, issues)
        end
      end

      issues
    end

    private def self.visit_emits(
      info : ClassInfo,
      declarations : Hash(String, TreeSitter::PropertyExtractor::EventDeclaration),
      unit : SourceUnit,
      node : TreeSitter::Node,
      issues : Array(SourceIssue),
    ) : Nil
      return if node.type.in?("method", "singleton_method", "singleton_class", "class", "module")

      if emit_call?(node)
        check_emit(info, declarations, unit, node, issues)
      end

      node.each_named_child do |child|
        visit_emits(info, declarations, unit, child, issues)
      end
    end

    private def self.emit_call?(node : TreeSitter::Node) : Bool
      receiver = node.child_by_field_name("receiver")
      method = node.child_by_field_name(node.type == "command" ? "name" : "method")
      node.type.in?("call", "command") && method.try(&.text) == "emit" &&
        (receiver.nil? || receiver.text == "self")
    end

    private def self.check_emit(
      info : ClassInfo,
      declarations : Hash(String, TreeSitter::PropertyExtractor::EventDeclaration),
      unit : SourceUnit,
      call : TreeSitter::Node,
      issues : Array(SourceIssue),
    ) : Nil
      values = argument_nodes(call)
      return if values.empty?

      event_node = values[0]
      event_name = literal_name(event_node)
      return unless event_name

      declaration = declarations[event_name]?
      unless declaration
        issues << emit_issue(
          unit,
          event_node,
          "event '#{event_name}' is not declared by '#{info.qualified_name}' " \
          "(declared events: #{declaration_names(info.events)})",
          "declare event :#{event_name} on '#{info.qualified_name}' or correct the emitted event name",
        )
        return
      end

      payload = payload_entries(values[1..])
      return unless payload
      entries, dynamic_keys = payload

      unless dynamic_keys
        declaration.payload.each do |field|
          next if entries.has_key?(field.name)
          issues << emit_issue(
            unit,
            event_node,
            "event '#{event_name}' payload is missing field '#{field.name}' " \
            "(#{field.type_name}, declared at #{declaration_location(info, declaration)})",
            "pass #{field.name}: <#{field.type_name}> to emit :#{event_name} " \
            "or correct the event declaration",
          )
        end
      end

      declared_fields = {} of String => TreeSitter::PropertyExtractor::EventPayloadField
      declaration.payload.each { |field| declared_fields[field.name] = field }

      entries.each do |name, entry|
        field = declared_fields[name]?
        unless field
          issues << emit_issue(
            unit,
            entry.key_node,
            "event '#{event_name}' payload field '#{name}' is not declared " \
            "(declared at #{declaration_location(info, declaration)})",
            "remove payload field '#{name}' or declare it on event :#{event_name}",
          )
          next
        end

        next if dynamic_keys
        check_value(unit, event_name, info, declaration, field, entry, issues)
      end
    end

    private def self.check_value(
      unit : SourceUnit,
      event_name : String,
      info : ClassInfo,
      declaration : TreeSitter::PropertyExtractor::EventDeclaration,
      field : TreeSitter::PropertyExtractor::EventPayloadField,
      entry : PayloadEntry,
      issues : Array(SourceIssue),
    ) : Nil
      kind = literal_kind(entry.value_node)
      return unless kind
      # The VM encodes payload Symbols as JSON strings, so a Symbol literal
      # satisfies a String field. Other field types still reject it.
      return if field.type == "string" && kind == "Symbol"

      unless type_matches?(field.type, kind)
        issues << emit_issue(
          unit,
          entry.value_node,
          "event '#{event_name}' payload field '#{field.name}' expects #{field.type_name}, " \
          "got #{kind} literal #{entry.value_node.text.inspect} " \
          "(declared at #{declaration_location(info, declaration)})",
          "pass a #{field.type_name} value for '#{field.name}'",
        )
        return
      end

      return unless field.type == "integer"
      value = integer_literal(entry.value_node)
      return unless value
      return if value >= BigInt.new(Int64::MIN) && value <= BigInt.new(Int64::MAX)

      issues << emit_issue(
        unit,
        entry.value_node,
        "event '#{event_name}' payload field '#{field.name}' Integer is outside the signed 64-bit range " \
        "(declared at #{declaration_location(info, declaration)})",
        "use an Integer value between -9223372036854775808 and 9223372036854775807",
      )
    end

    private def self.subscription_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue

      index.target_templates.each do |view|
        view.attributes.each do |attribute|
          name = attribute.name.downcase
          next unless name.starts_with?("on:")
          event_name = name[3..].split('.', 2).first
          next if event_name.empty?

          child = index.tags[attribute.tag.downcase]?
          next unless child
          next if child.events.empty?
          next if child.events.any? { |event| event.name == event_name }

          range = view.source_range(attribute.start, attribute.start + attribute.name.bytesize)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "child event '#{event_name}' is not declared on <#{attribute.tag.downcase}>; " \
            "declared events: #{declaration_names(child.events)} " \
            "(#{declaration_path(child)})",
            EVENT_PAYLOAD,
            "declare event :#{event_name} on '#{child.qualified_name}' " \
            "or bind one of the declared events",
          )
        end
      end

      issues
    end

    private def self.emit_issue(
      unit : SourceUnit,
      node : TreeSitter::Node,
      message : String,
      suggestion : String,
    ) : SourceIssue
      SourceIssue.new(
        unit.file.relative_path,
        unit.map,
        node.start_byte,
        node.end_byte,
        message,
        EVENT_PAYLOAD,
        suggestion,
      )
    end

    private def self.argument_nodes(call : TreeSitter::Node) : Array(TreeSitter::Node)
      values = [] of TreeSitter::Node
      call.child_by_field_name("arguments").try do |arguments|
        arguments.each_named_child { |argument| values << argument }
      end
      values
    end

    private def self.payload_entries(
      arguments : Array(TreeSitter::Node),
    ) : Tuple(Hash(String, PayloadEntry), Bool)?
      entries = {} of String => PayloadEntry
      return {entries, false} if arguments.empty?

      if arguments.size == 1
        node = unwrap_parentheses(arguments.first)
        if node.type == "hash"
          return {entries, collect_hash(node, entries)}
        end
      end

      if arguments.all? { |argument| argument.type.in?("pair", "hash_splat_argument") }
        dynamic = false
        arguments.each do |argument|
          if argument.type == "pair"
            dynamic = true unless add_pair(argument, entries)
          else
            dynamic = true
          end
        end
        return {entries, dynamic}
      end

      nil
    end

    private def self.collect_hash(node : TreeSitter::Node, entries : Hash(String, PayloadEntry)) : Bool
      dynamic = false
      node.each_named_child do |child|
        case child.type
        when "pair"
          dynamic = true unless add_pair(child, entries)
        else
          dynamic = true
        end
      end
      dynamic
    end

    private def self.add_pair(node : TreeSitter::Node, entries : Hash(String, PayloadEntry)) : Bool
      key = node.child_by_field_name("key") || first_named_child(node)
      value = node.child_by_field_name("value")
      value ||= node.named_child(1) if node.named_child_count > 1
      return false unless key && value

      name = literal_name(key)
      return false unless name
      entries[name] = PayloadEntry.new(key, value)
      true
    end

    private def self.literal_name(node : TreeSitter::Node) : String?
      case node.type
      when "simple_symbol"
        node.text.lchop(':')
      when "hash_key_symbol"
        node.text
      when "delimited_symbol"
        return nil if interpolated?(node)
        content = first_named_child(node, "string_content")
        value = content.try(&.text)
        value && !value.includes?('\\') ? value : nil
      when "string"
        return nil if interpolated?(node)
        range = TreeSitter::StringExtractor.string_content_range(node)
        return nil unless range
        value = node.source.byte_slice(range[0], range[1] - range[0])
        value.includes?('\\') ? nil : value
      end
    end

    private def self.literal_kind(node : TreeSitter::Node) : String?
      node = unwrap_parentheses(node)
      case node.type
      when "string"
        "String"
      when "integer"
        "Integer"
      when "float"
        "Float"
      when "true", "false"
        "Boolean"
      when "array"
        "Array"
      when "hash"
        "Hash"
      when "nil"
        "nil"
      when "simple_symbol", "delimited_symbol", "symbol"
        "Symbol"
      when "regex"
        "Regexp"
      when "unary"
        operand = node.child_by_field_name("operand") || first_named_child(node)
        if operand
          kind = literal_kind(operand)
          prefix = unary_prefix(node, operand)
          return kind if kind && kind.in?("Integer", "Float") && prefix.in?("+", "-")
        end
        nil
      end
    end

    private def self.type_matches?(field_type : String, kind : String) : Bool
      case field_type
      when "string"  then kind == "String"
      when "integer" then kind == "Integer"
      when "float"   then kind.in?("Float", "Integer")
      when "boolean" then kind == "Boolean"
      when "array"   then kind == "Array"
      when "hash"    then kind == "Hash"
      else                false
      end
    end

    private def self.integer_literal(node : TreeSitter::Node) : BigInt?
      node = unwrap_parentheses(node)
      case node.type
      when "integer"
        parse_integer(node.text)
      when "unary"
        operand = node.child_by_field_name("operand") || first_named_child(node)
        return nil unless operand
        value = integer_literal(operand)
        return nil unless value
        case unary_prefix(node, operand)
        when "-" then -value
        when "+" then value
        end
      end
    end

    private def self.unary_prefix(node : TreeSitter::Node, operand : TreeSitter::Node) : String
      node.source.byte_slice(node.start_byte, operand.start_byte - node.start_byte).strip
    end

    private def self.parse_integer(text : String) : BigInt?
      value = text.delete('_')
      base = 10
      if value.starts_with?("0x") || value.starts_with?("0X")
        value = value[2..]
        base = 16
      elsif value.starts_with?("0b") || value.starts_with?("0B")
        value = value[2..]
        base = 2
      elsif value.starts_with?("0o") || value.starts_with?("0O")
        value = value[2..]
        base = 8
      elsif value.starts_with?("0d") || value.starts_with?("0D")
        value = value[2..]
      elsif value.starts_with?("0") && value.size > 1
        base = 8
      end
      BigInt.new(value, base)
    rescue
      nil
    end

    private def self.unwrap_parentheses(node : TreeSitter::Node) : TreeSitter::Node
      while node.type == "parenthesized_statements" && node.named_child_count == 1
        node = node.named_child(0)
      end
      node
    end

    private def self.interpolated?(node : TreeSitter::Node) : Bool
      found = false
      node.each_named_child do |child|
        found = true if child.type == "interpolation"
      end
      found
    end

    private def self.first_named_child(node : TreeSitter::Node) : TreeSitter::Node?
      return nil if node.named_child_count == 0
      node.named_child(0)
    end

    private def self.first_named_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
      result = nil
      node.each_named_child do |child|
        result ||= child if child.type == type
      end
      result
    end

    private def self.declaration_names(events : Array(TreeSitter::PropertyExtractor::EventDeclaration)) : String
      events.map(&.name).join(", ")
    end

    private def self.declaration_path(info : ClassInfo) : String
      path = info.path
      path.empty? ? "component declaration" : path
    end

    private def self.declaration_location(
      info : ClassInfo,
      event : TreeSitter::PropertyExtractor::EventDeclaration,
    ) : String
      path = info.path
      path.empty? ? "line #{event.line}" : "#{path}:#{event.line}"
    end
  end
end
