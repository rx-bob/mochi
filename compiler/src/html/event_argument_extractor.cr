require "./event_argument"
require "./template_expression"
require "./template_attributes"

# One event attribute discovered in a template. The replacement callback in
# `rewrite` decides whether the DOM receives a plain handler name or a compiled
# row wrapper symbol.
struct EventCall
  MODIFIERS = ["prevent", "stop", "self"]

  getter event_name : String
  getter method_name : String
  getter arguments : Array(String)
  getter span : TemplateSourceSpan?
  getter modifiers : Array(String)

  def initialize(
    @event_name : String,
    @method_name : String,
    @arguments : Array(String),
    @span : TemplateSourceSpan? = nil,
  )
    suffix = @event_name.split('.', 2)[1]?
    @modifiers = suffix ? suffix.split('.') : [] of String
  end

  def event : String
    raw = if event_name.starts_with?("on:")
            event_name[3..]
          elsif event_name.starts_with?("on")
            event_name[2..]
          else
            event_name
          end
    raw.split('.', 2).first
  end

  # `on:<event>` is a compiled parent/child connection. `on<event>` retains
  # the native DOM event behavior.
  def component? : Bool
    event_name.starts_with?("on:")
  end
end

class EventArgumentExtractor
  EVENT_NAME = /\Aon:?[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*\z/

  # Rewrites event attributes with call arguments into a plain method name plus
  # a JSON descriptor list. Keeping the descriptors on the element lets the
  # loader pass typed values to the VM without evaluating Ruby in JavaScript.
  def self.process(
    html : String,
    locator : TemplateSourceLocator? = nil,
    parser : TemplateExpressionParser? = nil,
  ) : String
    rewritten, _calls = rewrite(html, locator, parser) do |call|
      render_event_attribute(call)
    end
    rewritten
  end

  # Rewrites every event attribute and returns the calls that were found.
  # List rows use this to replace the attribute with a generated Ruby wrapper
  # symbol instead of shipping argument expressions to the browser.
  def self.rewrite(
    html : String,
    locator : TemplateSourceLocator? = nil,
    parser : TemplateExpressionParser? = nil,
    &replacement : EventCall -> String
  ) : Tuple(String, Array(EventCall))
    expression_parser = parser || TemplateExpressionParser.new(locator)
    calls = [] of EventCall
    result = TemplateAttributes.rewrite(html, expression_parser) do |attribute|
      event_name = attribute.name.downcase
      if event_name.starts_with?("on:")
        validate_component_binding!(attribute, html, expression_parser)
      end
      next nil unless EVENT_NAME.matches?(event_name)
      value = attribute.value(html).strip
      expressions = expression_parser.scan(value, "event", validate: false)
      next nil unless expressions.size == 1 && expressions.first.full_text(value) == value
      content = expressions.first.source
      method_name, arguments = expression_parser.parse_call(content)
      validate_arguments(expression_parser, arguments)
      call = EventCall.new(event_name, method_name, arguments, locator.try(&.locate(content)))
      validate_modifiers(call)
      calls << call
      replacement.call(call)
    end
    {result, calls}
  end

  private def self.validate_component_binding!(attribute : TemplateAttribute, html : String,
                                               parser : TemplateExpressionParser)
    value = attribute.value(html).strip
    expressions = parser.scan(value, "event", validate: false)
    valid_name = EVENT_NAME.matches?(attribute.name.downcase)
    valid = valid_name && expressions.size == 1 && expressions.first.full_text(value) == value
    return if valid

    span = parser.locator.try(&.locate(attribute.name))
    raise TemplateExpressionError.new(
      "invalid child event binding #{attribute.name.inspect}=" \
      "#{attribute.value(html).inspect}; expected one braced handler, " \
      "for example on:action=\"{handle($event)}\"",
      span,
    )
  end

  # The loader reads modifiers from the same element as the event handler so
  # list rows and conditional branches keep their exact synchronous behavior.
  def self.render_modifiers(call : EventCall) : String
    return "" if call.modifiers.empty?
    %( data-mochi-modifiers-#{call.event}="#{call.modifiers.join(",")}")
  end

  private def self.render_event_attribute(call : EventCall) : String
    String.build do |io|
      io << call.event_name << "=\"{"
      io << call.method_name << "}\""

      unless call.arguments.empty?
        descriptors = call.arguments.map { |argument| EventArgumentDescriptor.parse(argument) }
        io << " data-mochi-args-" << call.event << "=\""
        io << escape_attribute(EventArgumentDescriptor.array_json(descriptors))
        io << "\""
      end
      io << render_modifiers(call)
    end
  end

  private def self.validate_modifiers(call : EventCall)
    unknown = call.modifiers.reject { |modifier| EventCall::MODIFIERS.includes?(modifier) }
    unless unknown.empty?
      raise TemplateExpressionError.new(
        "unknown event modifier #{unknown.first.inspect} on #{call.event_name.inspect}; " \
        "expected #{EventCall::MODIFIERS.join(", ")}",
        call.span
      )
    end
    if call.modifiers.uniq.size != call.modifiers.size
      raise TemplateExpressionError.new(
        "duplicate event modifier on #{call.event_name.inspect}",
        call.span
      )
    end
  end

  private def self.validate_arguments(parser : TemplateExpressionParser, arguments : Array(String))
    arguments.each do |argument|
      next if argument == "$event" || argument == "event" || argument == "$element" || argument == "element"
      parser.validate_source!(argument, "event argument")
    end
  end

  private def self.escape_attribute(value : String) : String
    value.gsub('&', "&amp;")
      .gsub('"', "&quot;")
      .gsub('<', "&lt;")
      .gsub('>', "&gt;")
      .gsub('{', "&#123;")
      .gsub('}', "&#125;")
  end
end
