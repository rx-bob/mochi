require "spec"
require "../../src/ruby/each_method_generator"
require "../../src/html/each_row_template"

private def list_row(
  id : Int32,
  items : String,
  item_name : String,
  index_name : String,
  declared_index : String?,
  bindings : Array(EachRowBindingDescriptor),
  children : Array(EachRowTemplate),
  events : Array(EachRowEventDescriptor),
  scope : Array(EachRowScope),
) : EachRowTemplate
  EachRowTemplate.new(
    id,
    items,
    item_name,
    index_name,
    declared_index,
    "<li></li>",
    bindings,
    events,
    children,
    scope
  )
end

describe EachMethodGenerator do
  it "generates one rows getter per root with nested loops evaluated in Ruby" do
    outer_scope = [EachRowScope.new("item", "index", nil)]
    inner_scope = outer_scope + [EachRowScope.new("entry", "k", "k")]
    inner = list_row(
      1,
      "item[:children]",
      "entry",
      "k",
      "k",
      [EachRowBindingDescriptor.new(0, "text", nil, "entry[:label]")],
      [] of EachRowTemplate,
      [] of EachRowEventDescriptor,
      inner_scope
    )
    outer = list_row(
      0,
      "@items",
      "item",
      "index",
      nil,
      [
        EachRowBindingDescriptor.new(0, "text", nil, "item.name"),
        EachRowBindingDescriptor.new(1, "text", nil, "index"),
      ],
      [inner],
      [] of EachRowEventDescriptor,
      outer_scope
    )

    code = EachMethodGenerator.generate_rows_method(outer)

    code.should contain("def __mochi_each_0_rows")
    code.should contain("__mochi_rows_0 = []")
    code.should contain("(@items || []).each_with_index do |__mochi_item_0, __mochi_index_0|")
    code.should contain("item = __mochi_item_0")
    code.should contain("index = __mochi_index_0")
    code.should contain("[item.name, index]")
    code.should contain("(item[:children] || []).each_with_index do |__mochi_item_1, __mochi_index_1|")
    code.should contain("entry = __mochi_item_1")
    code.should contain("k = __mochi_index_1")
    code.should contain("index = __mochi_index_1")
    code.should contain("[entry[:label]]")
    code.should contain("__mochi_rows_0.push([")
    code.should contain("[__mochi_rows_1]")
  end

  it "generates lexical aliases and argument expressions for row events" do
    outer_scope = [EachRowScope.new("ev", "index", nil)]
    inner_scope = outer_scope + [EachRowScope.new("child", "k", "k")]
    event = EachRowEventDescriptor.new(
      "click",
      "open_event",
      "__mochi_each_0_ev_1",
      [
        EventArgumentDescriptor.expression("ev[\"id\"]"),
        EventArgumentDescriptor.expression("child"),
        EventArgumentDescriptor.literal_number("7"),
        EventArgumentDescriptor.literal_string(%Q{\#{danger}"\\}),
        EventArgumentDescriptor.event,
      ],
      inner_scope
    )

    code = EachMethodGenerator.generate_event_wrapper(event)

    code.should contain("def __mochi_each_0_ev_1(")
    code.should contain("__mochi_scope_0_item")
    code.should contain("__mochi_scope_0_index")
    code.should contain("__mochi_scope_1_item")
    code.should contain("__mochi_scope_1_index")
    code.should contain("ev = __mochi_scope_0_item")
    code.should contain("index = __mochi_scope_0_index")
    code.should contain("child = __mochi_scope_1_item")
    code.should contain("k = __mochi_scope_1_index")
    code.should contain(%q{open_event(ev["id"], child, 7, "\#{danger}\"\\", __event)})
  end

  it "injects rows and wrappers before the class terminator" do
    ruby_code = <<-RUBY
class ItemList
  def initialize
    @items = []
  end

  def count
    @items.size
  end
end
RUBY

    row = list_row(
      3,
      "@items",
      "item",
      "index",
      nil,
      [EachRowBindingDescriptor.new(0, "text", nil, "item[:name]")],
      [] of EachRowTemplate,
      [] of EachRowEventDescriptor,
      [EachRowScope.new("item", "index", nil)]
    )

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "ItemList", [row])

    modified.should contain("def __mochi_each_3_rows")
    modified.should contain("def count")
    modified.should contain("@items = []")
    modified.index("def __mochi_each_3_rows").not_nil!.should be < modified.rindex("end").not_nil!
  end

  it "leaves classes without list rows unchanged" do
    code = "class Plain\nend\n"
    EachMethodGenerator.inject_methods_into_class(code, "Plain", [] of EachRowTemplate).should eq(code)
    EachMethodGenerator.generate_all_methods([] of EachRowTemplate, "Plain").should eq("")
  end
end
