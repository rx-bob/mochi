require "./event_argument"

# Compiler-only actions. The browser receives one entrypoint for the sequence,
# so a failed setter cannot start a second VM entry or flush partial effects.
struct EventAction
  getter kind : String
  getter target : String
  getter property : String?
  getter args : Array(EventArgumentDescriptor)
  getter span : TemplateSourceSpan?

  def initialize(@kind, @target, @property = nil,
                 @args = [] of EventArgumentDescriptor, @span = nil)
  end
end

class BoundProperty
  def self.expression(value : String, name : String, parser : TemplateExpressionParser) : TemplateExpression
    normalized = value.strip.matches?(/\A@[a-zA-Z_][a-zA-Z0-9_]*\z/) ? "{#{value.strip}}" : value
    expressions = parser.scan(normalized, "prop")
    unless expressions.size == 1 && expressions.first.full_text(normalized) == normalized.strip
      raise TemplateExpressionError.new("bind:#{name} requires exactly one @ivar placeholder", parser.locator.try(&.locate(value)))
    end
    expression = expressions.first
    unless expression.source.matches?(/\A@[a-zA-Z_][a-zA-Z0-9_]*\z/)
      raise TemplateExpressionError.new("bind:#{name} requires an instance variable, got #{expression.source}", expression.span)
    end
    expression
  end

  def self.event(name : String, tag : String) : String
    name == "checked" || tag.downcase == "select" ? "change" : "input"
  end
end
