require "../webcomponents/binding_manifest"
require "./inject_utils"

# Generates the method the VM calls before and after `initialize` to install
# declared props. The first pass assigns provided values and declared defaults
# so `initialize` can read them. The second pass re-applies provided values so
# an `initialize` assignment cannot silently clobber a parent-supplied prop.
class PropMethodGenerator
  END_KEYWORD     = "end"
  FALLBACK_OFFSET = 3
  METHOD_NAME     = "__mochi_apply_props"

  def self.inject_methods_into_class(
    ruby_code : String,
    class_name : String,
    props : Array(PropDescriptor),
  ) : String
    return ruby_code if props.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    InjectUtils.insert_code(ruby_code, insertion_point, generate_method(props))
  end

  def self.generate_method(props : Array(PropDescriptor)) : String
    String.build do |io|
      io << "\n  # auto-generated declared prop installation\n"
      io << "  def " << METHOD_NAME << "(__mochi_props, __mochi_initial)\n"
      props.each do |prop|
        key = prop.name
        io << "    if __mochi_props.key?(\"" << key << "\")\n"
        io << "      @" << key << " = __mochi_props[\"" << key << "\"]\n"
        io << "    elsif __mochi_initial\n"
        io << "      @" << key << " = " << default_expression(prop) << "\n"
        io << "    end\n"
      end
      io << "    nil\n"
      io << "  end\n"
    end
  end

  private def self.default_expression(prop : PropDescriptor) : String
    prop.default_code || "nil"
  end
end
