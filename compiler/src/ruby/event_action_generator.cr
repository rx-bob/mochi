require "../html/event_action"
require "./ruby_def"

class EventActionGenerator
  def self.required_arguments(methods : Hash(String, RubyDef)) : Hash(String, Int32)
    methods.transform_values do |method|
      # Match the VM's leading required positional count, including its
      # existing behavior for optional/rest and post-rest parameters.
      method.parameters.take_while do |parameter|
        parameter.matches?(/\A[a-z_][a-zA-Z0-9_]*\z/) || parameter.starts_with?("(")
      end.size
    end
  end

  def self.statements(actions : Array(EventAction), arities : Hash(String, Int32), indent : String) : String
    actions.map do |action|
      if action.kind == "set"
        "#{indent}#{action.target} = __event[:#{action.property}]"
      else
        args = action.args.map { |argument| ruby_argument(argument, action.span) }
        args << "__event" if args.empty? && arities[action.target]? == 1
        "#{indent}#{action.target}(#{args.join(", ")})"
      end
    end.join("\n")
  end

  def self.ruby_argument(argument : EventArgumentDescriptor, span : TemplateSourceSpan? = nil) : String
    case argument.kind
    when "event"
      "__event"
    when "expr"
      argument.value || "nil"
    when "literal"
      case argument.literal_type
      when "string"
        literal_string(argument.value || "")
      when "number"
        argument.value || "0"
      when "boolean"
        argument.value == "true" ? "true" : "false"
      else
        "nil"
      end
    else
      raise TemplateExpressionError.new("DOM elements cannot be passed to Ruby event handlers; use $event", span)
    end
  end

  private def self.literal_string(value : String) : String
    escaped = value.gsub('\\', "\\\\")
      .gsub('"', "\\\"")
      .gsub('#', "\\#")
      .gsub('\n', "\\n")
      .gsub('\r', "\\r")
      .gsub('\t', "\\t")
    "\"#{escaped}\""
  end
end
