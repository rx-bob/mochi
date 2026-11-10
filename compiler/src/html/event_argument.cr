require "json"

# One argument passed from a template event handler into a Ruby method.
# Literals carry their JSON type so the loader can reconstruct numbers and
# booleans without guessing from their spelling.
struct EventArgumentDescriptor
  getter kind : String
  getter literal_type : String?
  getter value : String?

  def initialize(@kind : String, @literal_type : String? = nil, @value : String? = nil)
  end

  def self.event : EventArgumentDescriptor
    new("event")
  end

  def self.element : EventArgumentDescriptor
    new("element")
  end

  def self.expression(value : String) : EventArgumentDescriptor
    new("expr", nil, value)
  end

  def self.literal_string(value : String) : EventArgumentDescriptor
    new("literal", "string", value)
  end

  def self.literal_number(value : String) : EventArgumentDescriptor
    new("literal", "number", value)
  end

  def self.literal_boolean(value : Bool) : EventArgumentDescriptor
    new("literal", "boolean", value ? "true" : "false")
  end

  def self.literal_null : EventArgumentDescriptor
    new("literal", "null", "null")
  end

  # Classifies one template argument. `$event` and `$element` are loader
  # supplied; quoted strings, integers, booleans, and nil become literals;
  # everything else stays a Ruby expression.
  def self.parse(raw : String) : EventArgumentDescriptor
    argument = raw.strip
    return event if argument == "$event" || argument == "event"
    return element if argument == "$element" || argument == "element"

    if argument.size >= 2 && (argument[0] == '\'' || argument[0] == '"') && argument[-1] == argument[0]
      return literal_string(unescape_string(argument[1...-1]))
    end

    return literal_number(argument) if argument.matches?(/\A-?\d+\z/)
    return literal_boolean(true) if argument == "true"
    return literal_boolean(false) if argument == "false"
    return literal_null if argument == "nil" || argument == "null"

    expression(argument)
  end

  def self.from_json_object(object : JSON::Any) : EventArgumentDescriptor
    kind = object["kind"].as_s
    literal_type = object["literal_type"]?.try { |value| value.as_s? }
    value = object["value"]?.try { |item| item.as_s? }
    new(kind, literal_type, value)
  end

  def write_fields(json : JSON::Builder)
    json.field "kind", kind
    json.field "literal_type", literal_type
    json.field "value", value
  end

  def self.array_json(descriptors : Array(EventArgumentDescriptor)) : String
    JSON.build do |json|
      json.array do
        descriptors.each do |descriptor|
          json.object { descriptor.write_fields(json) }
        end
      end
    end
  end

  private def self.unescape_string(value : String) : String
    String.build do |io|
      index = 0
      while index < value.size
        char = value[index]
        if char == '\\' && index + 1 < value.size
          index += 1
          escaped = value[index]
          case escaped
          when 'n'
            io << '\n'
          when 'r'
            io << '\r'
          when 't'
            io << '\t'
          else
            io << escaped
          end
        else
          io << char
        end
        index += 1
      end
    end
  end
end
