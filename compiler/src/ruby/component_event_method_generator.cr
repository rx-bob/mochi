require "../webcomponents/binding_manifest"
require "./inject_utils"

# Generates the Ruby `emit` bridge for a component that declares child events.
# Payload shape and value types are validated by the loader against the
# component manifest, so this method stays a thin host call and preserves Ruby
# values through the existing JSON bridge.
class ComponentEventMethodGenerator
  END_KEYWORD     = "end"
  FALLBACK_OFFSET = 3
  METHOD_NAME     = "emit"

  def self.inject_methods_into_class(
    ruby_code : String,
    class_name : String,
    events : Array(ComponentEventDescriptor),
  ) : String
    return ruby_code if events.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    InjectUtils.insert_code(ruby_code, insertion_point, generate_method)
  end

  def self.generate_method : String
    String.build do |io|
      io << "\n  # auto-generated child event emitter\n"
      io << "  def " << METHOD_NAME << "(__mochi_event, __mochi_payload = {})\n"
      io << "    Mochi.emit_child(__mochi_event.to_s, __mochi_payload)\n"
      io << "  end\n"
    end
  end
end
