require "./event_argument"
require "./template_expression"

# One scalar expression inside a compiled list row. `slot` is the position in
# the row's evaluated value array; `kind` is `text`, `html`, or `attr`.
# `trusted_markup` is true only for an explicit `Mochi.raw(...)` slot.
struct EachRowBindingDescriptor
  getter slot : Int32
  getter kind : String
  getter attr_name : String?
  getter expression : String
  getter span : TemplateSourceSpan?
  getter trusted_markup : Bool

  def initialize(
    @slot : Int32,
    @kind : String,
    @attr_name : String?,
    @expression : String,
    @span : TemplateSourceSpan? = nil,
    @trusted_markup : Bool = false,
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

  def initialize(
    @event : String,
    @handler : String,
    @wrapper_sym : String,
    @args : Array(EventArgumentDescriptor),
    @scope : Array(EachRowScope) = [] of EachRowScope,
    @span : TemplateSourceSpan? = nil,
  )
  end
end

# A compiled list row: a static template with value slots, plus the nested
# each trees whose rows mount at the template's comment anchors.
class EachRowTemplate
  getter block_id : Int32
  getter items_expression : String
  getter item_name : String
  getter index_name : String
  getter declared_index : String?
  getter template : String
  getter bindings : Array(EachRowBindingDescriptor)
  getter events : Array(EachRowEventDescriptor)
  getter children : Array(EachRowTemplate)
  getter scope : Array(EachRowScope)
  # Ruby expression evaluated in the VM for each row. The loader receives only
  # the evaluated value as the row's fourth tuple element.
  getter key_expression : String?
  # Source span of the list expression, used for runtime duplicate-key errors.
  getter span : TemplateSourceSpan?

  def initialize(
    @block_id : Int32,
    @items_expression : String,
    @item_name : String,
    @index_name : String,
    @declared_index : String?,
    @template : String,
    @bindings : Array(EachRowBindingDescriptor),
    @events : Array(EachRowEventDescriptor),
    @children : Array(EachRowTemplate),
    @scope : Array(EachRowScope),
    @key_expression : String? = nil,
    @span : TemplateSourceSpan? = nil,
  )
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

  # Visits this row and every nested row, outermost first.
  def each_template(&block : EachRowTemplate ->)
    yield self
    children.each { |child| child.each_template(&block) }
  end

  def all_events : Array(EachRowEventDescriptor)
    result = [] of EachRowEventDescriptor
    each_template { |row| result.concat(row.events) }
    result
  end
end
