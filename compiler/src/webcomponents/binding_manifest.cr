require "../html/event_argument"
require "../html/each_row_template"
require "../html/template_expression"
require "../ruby/inject_utils"
require "../ruby/ruby_def"
require "../tree-sitter/method_body_extractor"

struct BindingDescriptor
  property id : Int32
  property path : Array(Int32)
  property kind : String
  property attr_name : String?
  # `text` or `boolean` for attribute bindings; nil for every other kind.
  property attr_kind : String?
  property template_text : String?
  property getter_sym : String
  property getter_expr : String?
  property branches : Array(ConditionalBranchDescriptor)
  property setter_sym : String?
  property template_start : Int32?
  property template_end : Int32?
  property scope : Array(String)
  property span : TemplateSourceSpan?
  property each_rows : EachRowTemplate?
  property trusted_markup : Bool

  def initialize(
    @id : Int32,
    @path : Array(Int32),
    @kind : String,
    @getter_sym : String,
    @attr_name : String? = nil,
    @template_text : String? = nil,
    @getter_expr : String? = nil,
    @branches : Array(ConditionalBranchDescriptor) = [] of ConditionalBranchDescriptor,
    @setter_sym : String? = nil,
    @template_start : Int32? = nil,
    @template_end : Int32? = nil,
    @scope : Array(String) = [] of String,
    @span : TemplateSourceSpan? = nil,
    @each_rows : EachRowTemplate? = nil,
    @trusted_markup : Bool = false,
    @attr_kind : String? = nil,
  )
  end
end

struct ConditionalBranchDescriptor
  property html_template : String
  property bindings : Array(BindingDescriptor)
  property events : Array(EventDescriptor)

  def initialize(
    @html_template : String,
    @bindings : Array(BindingDescriptor) = [] of BindingDescriptor,
    @events : Array(EventDescriptor) = [] of EventDescriptor,
  )
  end
end

struct EventDescriptor
  property path : Array(Int32)
  property event : String
  property method_sym : String
  property args : Array(EventArgumentDescriptor)
  # True for a parent binding written as `on:<event>`. The compiled output is
  # still an ordinary delegated DOM event, but the marker records that this
  # connection targets a child component event instead of a native browser
  # event.
  property component : Bool

  def initialize(
    @path : Array(Int32),
    @event : String,
    @method_sym : String,
    @args : Array(EventArgumentDescriptor) = [] of EventArgumentDescriptor,
    @component : Bool = false,
  )
  end

  def method_name : String
    method_sym
  end
end

# One field in a declared child-event payload. The type names match the prop
# schema so the loader can validate values before they reach the parent.
struct EventPayloadDescriptor
  property name : String
  property type : String

  def initialize(@name : String, @type : String)
  end
end

# Compact runtime schema for a Ruby-declared child event. Only the event name,
# payload contract, and source location travel in the manifest.
struct ComponentEventDescriptor
  property name : String
  property payload : Array(EventPayloadDescriptor)
  property source_file : String?
  property source_line : Int32

  def initialize(
    @name : String,
    @payload : Array(EventPayloadDescriptor) = [] of EventPayloadDescriptor,
    @source_file : String? = nil,
    @source_line : Int32 = 0,
  )
  end
end

# Compact runtime validation data for one declared Ruby prop. Only the value
# type, required flag, default presence, and source location travel in the
# manifest; the default expression itself stays in the component's Ruby code.
struct PropDescriptor
  property name : String
  property type : String
  property required : Bool
  property default : Bool
  # Ruby source for the default expression. It stays out of the manifest JSON
  # and is only used when generating `__mochi_apply_props`.
  property default_code : String?
  property source_file : String?
  property source_line : Int32

  def initialize(
    @name : String,
    @type : String,
    @required : Bool = false,
    @default : Bool = false,
    @default_code : String? = nil,
    @source_file : String? = nil,
    @source_line : Int32 = 0,
  )
  end
end

class ComponentManifest
  property tag_name : String
  property class_name : String
  property chi_file : String
  property html_template : String
  property css : String
  property bindings : Array(BindingDescriptor)
  property events : Array(EventDescriptor)
  property helper_chi : String?
  property source_file : String?
  property source_line : Int32
  property method_lines : Hash(String, Int32)
  property props : Array(PropDescriptor)
  property emits : Array(ComponentEventDescriptor)

  def initialize(
    @tag_name : String,
    @class_name : String,
    @chi_file : String,
    @html_template : String,
    @css : String,
    @bindings : Array(BindingDescriptor),
    @events : Array(EventDescriptor) = [] of EventDescriptor,
    @helper_chi : String? = nil,
    @source_file : String? = nil,
    @source_line : Int32 = 0,
    @method_lines : Hash(String, Int32) = {} of String => Int32,
    @props : Array(PropDescriptor) = [] of PropDescriptor,
    @emits : Array(ComponentEventDescriptor) = [] of ComponentEventDescriptor,
  )
  end

  def binding_ids : Array(Int32)
    bindings.map(&.id)
  end

  def event_names : Array(String)
    events.map(&.event).uniq
  end

  # Every binding in the component, including bindings nested inside
  # conditional branch templates. Getter methods are generated for all of them.
  def all_bindings : Array(BindingDescriptor)
    result = [] of BindingDescriptor
    bindings.each { |binding| collect_bindings(binding, result) }
    result
  end

  def all_events : Array(EventDescriptor)
    result = events.dup
    all_bindings.each do |binding|
      binding.branches.each { |branch| result.concat(branch.events) }
    end
    result
  end

  private def collect_bindings(binding : BindingDescriptor, result : Array(BindingDescriptor))
    result << binding
    binding.branches.each do |branch|
      branch.bindings.each { |child| collect_bindings(child, result) }
    end
  end
end

class RubyBindingRewriter
  def self.rewrite(ruby_code : String, class_name : String, bindings : Array(BindingDescriptor), removed_methods : Array(RubyDef) = [] of RubyDef) : String
    method_names = removed_methods.compact_map(&.name)
    code = remove_methods(ruby_code, class_name, method_names)
    inject_getters(code, class_name, bindings)
  end

  def self.inject_getters(ruby_code : String, class_name : String, bindings : Array(BindingDescriptor)) : String
    all_bindings = flatten_bindings(bindings)
    return ruby_code if all_bindings.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, "end", 1)
    return ruby_code unless insertion_point

    methods_code = String.build do |io|
      setters = [] of String

      all_bindings.each do |binding|
        # List rows own a generated rows getter; injecting `__mochi_bind_N`
        # would either duplicate work or recurse through the same symbol.
        next if binding.kind == "each" && binding.getter_sym.starts_with?("__mochi_each_")

        expression = expression_for(binding)
        io << "\n  def " << binding.getter_sym << "; " << expression << "; end\n"

        setter_sym = binding.setter_sym
        next unless setter_sym
        next if setters.includes?(setter_sym)

        setters << setter_sym
        event_key = binding.attr_name == "checked" ? "checked" : "value"
        io << "\n  def " << setter_sym << "(event); " << expression << " = event[:" << event_key << "]; end\n"
      end
    end

    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  private def self.flatten_bindings(bindings : Array(BindingDescriptor)) : Array(BindingDescriptor)
    result = [] of BindingDescriptor
    bindings.each do |binding|
      result << binding
      binding.branches.each do |branch|
        result.concat(flatten_bindings(branch.bindings))
      end
    end
    result
  end

  def self.expression_for(binding : BindingDescriptor) : String
    return binding.getter_expr.not_nil! if binding.getter_expr

    template = binding.template_text || ""
    expression = template[/\{([^}]+)\}/, 1]? || template
    expression = expression.strip
    expression = expression[1..-2] if expression.starts_with?("{") && expression.ends_with?("}")

    # Strict binding syntax leaves `@foo` as an ivar read and `foo` as a
    # method call. Prefixing `@` here would silently change method bindings.
    expression
  end

  def self.remove_methods(ruby_code : String, class_name : String, method_names : Array(String)) : String
    return ruby_code if method_names.empty?

    TreeSitter::MethodBodyExtractor.remove_methods(ruby_code, class_name, method_names)
  end
end
