require "set"

require "../../html/event_argument_extractor"
require "../../html/template_expression"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Resolves authored template callbacks and literal timer callbacks against
  # the shared project index. A handler is only reported missing when the
  # component's instance-method inventory is closed; dynamic receivers, row
  # locals, property readers, and unresolved external ancestors stay unknown.
  module Handlers
    UNKNOWN_HANDLER = "correctness/unknown-handler"
    TIMER_CALLBACK  = "correctness/timer-callback"

    BARE_METHOD     = /\A[a-z_][a-zA-Z0-9_]*[!?=]?\z/
    TIMER_METHODS   = Set{"after", "every"}
    TIMER_MAX_DELAY = 2_147_483_647_i64
    EVENT_ARGUMENTS = Set{"$event", "event", "$element", "element"}

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      issues = [] of SourceIssue
      if index.config.enabled?(UNKNOWN_HANDLER)
        issues.concat(handler_issues(index))
      end
      if index.config.enabled?(TIMER_CALLBACK)
        issues.concat(timer_issues(index))
      end

      diagnostics = issues.compact_map do |issue|
        severity = index.config.severity_for(issue.rule)
        severity ? issue.diagnostic(severity) : nil
      end
      Diagnostics.sort(diagnostics)
    end

    private def self.handler_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue
      parser = TemplateExpressionParser.new

      index.target_templates.each do |view|
        owner = index.class_info(view.owner_name)
        next unless owner

        view.attributes.each do |attribute|
          attribute_name = attribute.name.downcase
          next unless EventArgumentExtractor::EVENT_NAME.matches?(attribute_name)

          raw_value = attribute.value(view.text)
          value = raw_value.strip
          next if value.empty?

          expressions = begin
            parser.scan(value, "event", validate: false)
          rescue TemplateExpressionError
            next
          end
          next unless expressions.size == 1
          expression = expressions.first
          next unless expression.full_text(value) == value

          method_name, _arguments = parser.parse_call(expression.source)
          handler_name, handler_offset = normalize_handler(method_name)
          next unless handler_name
          next if EVENT_ARGUMENTS.includes?(handler_name)
          next if reader?(owner, handler_name)

          leading = leading_whitespace(raw_value)
          inner_start = attribute.value_start + leading + expression.template_start + 1
          inner_start = skip_whitespace(view.text, inner_start)
          method_start = view.source_byte(inner_start)
          next if view.scope_at(method_start).includes?(handler_name)

          status = instance_method_status(index, owner, handler_name)
          next unless status == false

          range = view.source_range(inner_start + handler_offset, inner_start + handler_offset + handler_name.bytesize)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "template handler '#{handler_name}' is not defined on '#{owner.qualified_name}'",
            UNKNOWN_HANDLER,
            "define '#{handler_name}' on '#{owner.qualified_name}' or correct the handler name",
          )
        end
      end

      issues
    end

    private def self.normalize_handler(method_name : String) : Tuple(String?, Int32)
      if BARE_METHOD.matches?(method_name)
        {method_name, 0}
      elsif method_name.starts_with?("self.")
        name = method_name[5..]
        BARE_METHOD.matches?(name) ? {name, 5} : {nil, 0}
      else
        {nil, 0}
      end
    end

    private def self.timer_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue

      index.classes.each_value do |info|
        info.method_definitions.each do |method|
          next if method.singleton
          next unless index.selected.includes?(method.unit_path)
          body = method.body
          unit = index.unit(method.unit_path)
          next unless body && unit

          visit_timer_calls(index, info, unit, body, issues)
        end
      end

      issues
    end

    private def self.visit_timer_calls(
      index : ProjectIndex,
      info : ClassInfo,
      unit : SourceUnit,
      node : TreeSitter::Node,
      issues : Array(SourceIssue),
    ) : Nil
      return if node.type.in?("method", "singleton_method", "class", "module")

      if timer_call?(node)
        if issue = timer_issue(index, info, unit, node)
          issues << issue
        end
      end

      node.each_named_child do |child|
        visit_timer_calls(index, info, unit, child, issues)
      end
    end

    private def self.timer_call?(node : TreeSitter::Node) : Bool
      return false unless node.type == "call"
      receiver = node.child_by_field_name("receiver")
      return false unless receiver && receiver.text == "Mochi"
      method = node.child_by_field_name("method")
      !!method && TIMER_METHODS.includes?(method.text)
    end

    private def self.timer_issue(
      index : ProjectIndex,
      info : ClassInfo,
      unit : SourceUnit,
      call : TreeSitter::Node,
    ) : SourceIssue?
      arguments = call.child_by_field_name("arguments")
      return nil unless arguments
      values = [] of TreeSitter::Node
      arguments.each_named_child { |argument| values << argument }
      return nil if values.size < 2

      delay = values[0]
      callback = values[1]
      timer = call.child_by_field_name("method").not_nil!.text
      name = literal_callback_name(callback)
      unless name
        if kind = non_name_callback_kind(callback)
          return timer_source_issue(
            unit,
            callback,
            "Mochi.#{timer} callback #{callback.text.inspect} must be a String or Symbol " \
            "naming a component method, got #{kind}",
            "pass a literal String or Symbol method name",
          )
        end
        if message = delay_problem(timer, delay)
          return timer_source_issue(
            unit,
            delay,
            message,
            "pass a literal Integer delay from 0 through 2_147_483_647 milliseconds",
          )
        end
        return nil
      end

      if name.empty?
        return timer_source_issue(
          unit,
          callback,
          "Mochi.#{timer} callback must name a component method",
          "pass a non-empty literal String or Symbol method name",
        )
      end

      status = instance_method_status(index, info, name)
      if status == false
        return timer_source_issue(
          unit,
          callback,
          "Mochi.#{timer} callback '#{name}' is not defined on '#{info.qualified_name}'",
          "define '#{name}' on '#{info.qualified_name}' or pass a valid method name",
        )
      end

      if status == true
        if method = instance_method(index, info, name)
          required = required_argument_count(method)
          if required > 0
            label = required == 1 ? "argument" : "arguments"
            return timer_source_issue(
              unit,
              callback,
              "Mochi.#{timer} callback '#{name}' requires #{required} required #{label}; " \
              "timer callbacks are invoked without arguments",
              "define '#{name}' with no required arguments or make the input optional",
            )
          end
        end
      end

      if message = delay_problem(timer, delay)
        return timer_source_issue(
          unit,
          delay,
          message,
          "pass a literal Integer delay from 0 through 2_147_483_647 milliseconds",
        )
      end

      nil
    end

    private def self.timer_source_issue(
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
        TIMER_CALLBACK,
        suggestion,
      )
    end

    private def self.literal_callback_name(node : TreeSitter::Node) : String?
      case node.type
      when "simple_symbol"
        node.text.lchop(":")
      when "delimited_symbol"
        return nil if interpolated?(node)
        content = first_named_child(node, "string_content")
        content.try(&.text)
      when "string"
        return nil if interpolated?(node)
        range = TreeSitter::StringExtractor.string_content_range(node)
        return nil unless range
        node.source.byte_slice(range[0], range[1] - range[0])
      end
    end

    private def self.non_name_callback_kind(node : TreeSitter::Node) : String?
      case node.type
      when "integer"       then "Integer"
      when "float"         then "Float"
      when "true", "false" then "Boolean"
      when "nil"           then "nil"
      when "array"         then "Array"
      when "hash"          then "Hash"
      when "unary"
        operand = node.child_by_field_name("operand")
        operand ? non_name_callback_kind(operand) : nil
      end
    end

    private def self.interpolated?(node : TreeSitter::Node) : Bool
      found = false
      node.each_named_child do |child|
        found = true if child.type == "interpolation"
      end
      found
    end

    private def self.first_named_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
      result = nil
      node.each_named_child do |child|
        result ||= child if child.type == type
      end
      result
    end

    # Mirrors EventActionGenerator.required_arguments: the VM counts leading
    # required positional parameters, then stops at an optional, rest, keyword,
    # or block parameter.
    private def self.required_argument_count(method : MethodInfo) : Int32
      parameters = method.node.child_by_field_name("parameters")
      return 0 unless parameters

      count = 0
      index = 0
      while index < parameters.named_child_count
        parameter = parameters.named_child(index)
        break unless parameter.type.in?("identifier", "destructured_parameter")
        count += 1
        index += 1
      end
      count
    end

    private def self.delay_problem(timer : String, node : TreeSitter::Node) : String?
      if value = literal_integer(node)
        return nil if value >= 0 && value <= TIMER_MAX_DELAY
        return "Mochi.#{timer} delay #{node.text.inspect} must be an Integer from 0 through 2_147_483_647"
      end

      if kind = non_integer_literal_kind(node)
        return "Mochi.#{timer} delay #{node.text.inspect} must be an Integer from 0 through 2_147_483_647, got #{kind}"
      end

      nil
    end

    private def self.literal_integer(node : TreeSitter::Node) : Int64?
      case node.type
      when "integer"
        parse_integer(node.text)
      when "unary"
        operand = node.child_by_field_name("operand")
        return nil unless operand
        value = literal_integer(operand)
        return nil unless value
        node.text.starts_with?('-') ? -value : value
      end
    end

    private def self.parse_integer(text : String) : Int64?
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
      end
      value.to_i64?(base)
    end

    private def self.non_integer_literal_kind(node : TreeSitter::Node) : String?
      case node.type
      when "float"                                       then "Float"
      when "string"                                      then "String"
      when "simple_symbol", "delimited_symbol", "symbol" then "Symbol"
      when "true", "false"                               then "Boolean"
      when "nil"                                         then "nil"
      when "array"                                       then "Array"
      when "hash"                                        then "Hash"
      when "unary"
        operand = node.child_by_field_name("operand")
        operand ? non_integer_literal_kind(operand) : nil
      end
    end

    private def self.reader?(info : ClassInfo, name : String) : Bool
      return true if info.attribute_readers.includes?(name)
      info.props.any? { |prop| prop.name == name }
    end

    private def self.local_instance_method?(info : ClassInfo, name : String) : Bool
      info.methods.has_key?(name) || reader?(info, name)
    end

    private def self.instance_method_status(index : ProjectIndex, info : ClassInfo, name : String) : Bool?
      return true if local_instance_method?(info, name)
      return nil if info.open?

      index.ancestors(info).each do |ancestor|
        return true if local_instance_method?(ancestor, name)
        return nil if ancestor.open?
      end
      false
    end

    private def self.instance_method(index : ProjectIndex, info : ClassInfo, name : String) : MethodInfo?
      info.methods[name]? || index.ancestors(info).compact_map { |ancestor| ancestor.methods[name]? }.first?
    end

    private def self.leading_whitespace(value : String) : Int32
      index = 0
      while index < value.bytesize && TemplateExpressionParser.whitespace?(value.byte_at(index))
        index += 1
      end
      index
    end

    private def self.skip_whitespace(text : String, index : Int32) : Int32
      cursor = index
      while cursor < text.bytesize && TemplateExpressionParser.whitespace?(text.byte_at(cursor))
        cursor += 1
      end
      cursor
    end
  end
end
