require "../ruby/inject_utils"
require "../ruby/ruby_def"
require "../tree-sitter/method_body_extractor"

struct BindingDescriptor
  property id : Int32
  property path : Array(Int32)
  property kind : String
  property attr_name : String?
  property template_text : String?
  property getter_sym : String
  property getter_expr : String?

  def initialize(@id : Int32, @path : Array(Int32), @kind : String, @getter_sym : String, @attr_name : String? = nil, @template_text : String? = nil, @getter_expr : String? = nil)
  end
end

struct EventDescriptor
  property path : Array(Int32)
  property event : String
  property method_sym : String
  property args : Array(String)

  def initialize(@path : Array(Int32), @event : String, @method_sym : String, @args : Array(String) = [] of String)
  end

  def method_name : String
    method_sym
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

  def initialize(
    @tag_name : String,
    @class_name : String,
    @chi_file : String,
    @html_template : String,
    @css : String,
    @bindings : Array(BindingDescriptor),
    @events : Array(EventDescriptor) = [] of EventDescriptor,
  )
  end

  def binding_ids : Array(Int32)
    bindings.map(&.id)
  end

  def event_names : Array(String)
    events.map(&.event).uniq
  end
end

class RubyBindingRewriter
  def self.rewrite(ruby_code : String, class_name : String, bindings : Array(BindingDescriptor), removed_methods : Array(RubyDef) = [] of RubyDef) : String
    method_names = removed_methods.compact_map(&.name)
    code = remove_methods(ruby_code, class_name, method_names)
    inject_getters(code, class_name, bindings)
  end

  def self.inject_getters(ruby_code : String, class_name : String, bindings : Array(BindingDescriptor)) : String
    return ruby_code if bindings.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, "end", 1)
    return ruby_code unless insertion_point

    methods_code = bindings.map { |binding|
      expression = expression_for(binding)
      "\n  def #{binding.getter_sym}; #{expression}; end\n"
    }.join

    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
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
