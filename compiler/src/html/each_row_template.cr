require "./event_argument"
require "./event_action"
require "./template_expression"
require "./attribute_conditional_extractor"
require "./attribute_hash_extractor"

# One scalar expression inside a compiled list row. `slot` is the position in
# the row's evaluated value array; `kind` is `text`, `html`, or `attr`.
# `trusted_markup` is true only for an explicit `Mochi.raw(...)` slot.
# `attr_kind` is `text` or `boolean` for attribute slots.
struct EachRowBindingDescriptor
  getter slot : Int32
  getter kind : String
  getter attr_name : String?
  getter expression : String
  getter span : TemplateSourceSpan?
  getter trusted_markup : Bool
  getter attr_kind : String?

  def initialize(
    @slot : Int32,
    @kind : String,
    @attr_name : String?,
    @expression : String,
    @span : TemplateSourceSpan? = nil,
    @trusted_markup : Bool = false,
    @attr_kind : String? = nil,
  )
  end
end

# One lexical loop name pair. `index_name` is the name available to template
# expressions (the declared name or `index`); `declared_index` remembers the
# source spelling so generated Ruby can expose both names.
struct EachRowScope
  getter item_name : String
  getter index_name : String
  getter declared_index : String?

  def initialize(@item_name : String, @index_name : String, @declared_index : String? = nil)
  end
end

# DOM context containing an each anchor. Row templates are parsed relative to
# this element so table and foreign-content nodes retain their browser shape.
struct EachRowDomContext
  getter tag : String
  getter namespace : String

  def initialize(@tag : String = "body", @namespace : String = "html")
  end
end

# One event inside a list row. Events with arguments call a generated wrapper
# that evaluates the arguments in the current row scope and then invokes the
# user's handler. `scope` is the enclosing lexical chain, outermost first.
struct EachRowEventDescriptor
  getter event : String
  getter handler : String
  getter wrapper_sym : String
  getter args : Array(EventArgumentDescriptor)
  getter scope : Array(EachRowScope)
  getter span : TemplateSourceSpan?
  getter component : Bool
  getter modifiers : Array(String)
  getter actions : Array(EventAction)

  def initialize(
    @event : String,
    @handler : String,
    @wrapper_sym : String,
    @args : Array(EventArgumentDescriptor),
    @scope : Array(EachRowScope) = [] of EachRowScope,
    @span : TemplateSourceSpan? = nil,
    @component : Bool = false,
    @modifiers : Array(String) = [] of String,
    @actions : Array(EventAction) = [] of EventAction,
  )
  end
end

# A fragment retains its lexical scope without introducing a loop variable.
# Rows and conditional branches share slots, events, and structural children.
class EachRowFragment
  getter block_id : Int32
  getter template : String
  getter bindings : Array(EachRowBindingDescriptor)
  getter events : Array(EachRowEventDescriptor)
  getter children : Array(EachRowTemplate)
  getter scope : Array(EachRowScope)
  getter span : TemplateSourceSpan?
  getter attribute_conditionals : Array(ExtractedAttributeConditional)
  getter attribute_hashes : Array(ExtractedAttributeHash)
  getter context_tag : String
  getter context_namespace : String
  getter conditionals : Array(EachRowConditional)

  def initialize(@block_id, @template, @bindings, @events, @children, @scope,
                 @span : TemplateSourceSpan? = nil,
                 @attribute_conditionals = [] of ExtractedAttributeConditional,
                 @attribute_hashes = [] of ExtractedAttributeHash,
                 @context_tag = "body", @context_namespace = "html",
                 @conditionals = [] of EachRowConditional)
  end

  def scope_names : Array(String)
    names = [] of String
    scope.each do |entry|
      names << entry.item_name unless names.includes?(entry.item_name)
      names << entry.index_name unless names.includes?(entry.index_name)
      names << "index" unless names.includes?("index")
    end
    names
  end

  def each_template(&block : EachRowFragment ->)
    yield self
    children.each { |child| child.each_template(&block) }
    conditionals.each do |conditional|
      conditional.branches.each { |branch| branch.each_template(&block) }
    end
  end

  def all_events : Array(EachRowEventDescriptor)
    result = [] of EachRowEventDescriptor
    each_template { |fragment| result.concat(fragment.events) }
    result
  end
end

class EachRowConditional
  getter id : Int32
  getter conditions : Array(String?)
  getter branches : Array(EachRowFragment)
  getter span : TemplateSourceSpan?

  def initialize(@id, @conditions, @branches, @span = nil)
  end
end

class EachRowTemplate < EachRowFragment
  getter items_expression : String
  getter item_name : String
  getter index_name : String
  getter declared_index : String?
  getter key_expression : String?

  def initialize(block_id : Int32, @items_expression : String, @item_name : String,
                 @index_name : String, @declared_index : String?, template : String,
                 bindings : Array(EachRowBindingDescriptor), events : Array(EachRowEventDescriptor),
                 children : Array(EachRowTemplate), scope : Array(EachRowScope),
                 @key_expression : String? = nil, span : TemplateSourceSpan? = nil,
                 attribute_conditionals = [] of ExtractedAttributeConditional,
                 attribute_hashes = [] of ExtractedAttributeHash,
                 context_tag = "body", context_namespace = "html",
                 conditionals = [] of EachRowConditional)
    super(block_id, template, bindings, events, children, scope, span,
      attribute_conditionals, attribute_hashes, context_tag, context_namespace, conditionals)
  end
end

# Shared by every fragment compiled for a component, including branch events.
class EachRowIds
  property next_id : Int32

  def initialize(@next_id : Int32); end

  def take : Int32
    id = @next_id
    @next_id += 1
    id
  end
end
