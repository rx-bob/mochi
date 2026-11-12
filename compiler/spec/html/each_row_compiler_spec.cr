require "spec"
require "../../src/html/each_row_compiler"

private def compile_row_template(html : String) : EachRowTemplate
  blocks = EachProcessor.extract_each_blocks(html)
  roots = EachProcessor.roots(blocks)
  roots.size.should eq(1)
  EachRowCompiler.compile(roots.first, TemplateExpressionParser.new)
end

describe EachRowCompiler do
  it "keeps nested loop scopes distinct and compiles events with row arguments" do
    row = compile_row_template(%Q{
      <ul>
        {each @events as ev, idx}
          <li data-id="{ev["id"]}">
            {each ev["children"] as child, ci}
              <button class="child" title="{child}-{ev["id"]}" onclick="{pick(ev["id"], child, ci)}">{label(ev, idx)}</button>
            {end}
          </li>
        {end}
      </ul>
    })

    row.block_id.should eq(0)
    row.items_expression.should eq("@events")
    row.item_name.should eq("ev")
    row.index_name.should eq("idx")
    row.declared_index.should eq("idx")
    row.scope_names.should eq(["ev", "idx", "index"])
    row.template.should contain("<!--mochi-each-1-->")
    row.template.should_not contain("{each ")
    row.template.should_not contain("{end}")

    id_binding = row.bindings.find! { |binding| binding.kind == "attr" && binding.attr_name == "data-id" }
    id_binding.expression.should eq(%Q{ev["id"]})

    row.children.size.should eq(1)
    child = row.children.first
    child.block_id.should eq(1)
    child.items_expression.should eq(%Q{ev["children"]})
    child.item_name.should eq("child")
    child.index_name.should eq("ci")
    child.scope_names.should eq(["ev", "idx", "index", "child", "ci"])

    titles = child.bindings.select { |binding| binding.attr_name == "title" }
    titles.map(&.expression).should eq(["child", %Q{ev["id"]}])
    label_binding = child.bindings.find! { |binding| binding.expression == "label(ev, idx)" }
    label_binding.kind.should eq("text")
    label_binding.trusted_markup.should be_false

    event = child.all_events.first
    event.event.should eq("click")
    event.handler.should eq("pick")
    event.wrapper_sym.should eq("__mochi_each_1_ev_1")
    event.scope.map(&.item_name).should eq(["ev", "child"])
    event.args.size.should eq(3)
    event.args.map(&.kind).should eq(["expr", "expr", "expr"])
    event.args.map(&.value).should eq([%Q{ev["id"]}, "child", "ci"])
    child.template.should contain(%Q{data-mochi-click="__mochi_each_1_ev_1"})
    child.template.should_not contain("data-mochi-args")
  end

  it "keeps separate arguments for repeated events in one row" do
    row = compile_row_template(%Q{
      {each @items as item}
        <button class="first" onclick="{pick(item[:first])}">first</button>
        <button class="second" onclick="{pick(item[:second])}">second</button>
      {end}
    })

    row.events.size.should eq(2)
    row.events[0].handler.should eq("pick")
    row.events[0].args.map(&.value).should eq(["item[:first]"])
    row.events[1].handler.should eq("pick")
    row.events[1].args.map(&.value).should eq(["item[:second]"])
    row.events.map(&.wrapper_sym).should eq(["__mochi_each_0_ev_1", "__mochi_each_0_ev_2"])
  end

  it "compiles a default index name and keeps the declared alias available" do
    row = compile_row_template(%Q{
      {each @items as item}
        <span class="row {item[:kind]}">{item[:label]} at {index}</span>
      {end}
    })

    row.index_name.should eq("index")
    row.declared_index.should be_nil
    row.scope_names.should eq(["item", "index"])
    row.bindings.map(&.expression).should eq([%Q{item[:kind]}, %Q{item[:label]}, "index"])
    row.bindings.map(&.kind).should eq(["attr", "text", "text"])
  end

  it "compiles explicit key expressions and list source spans" do
    source = %Q{
      {each @groups as group, key: group["id"]}
        <section>
          {each group["items"] as item, item_index, key: item["id"]}
            <span>{item["label"]}</span>
          {end}
        </section>
      {end}
    }
    parser = TemplateExpressionParser.new(
      TemplateSourceLocator.new(source, "lib/keyed_rows.rb")
    )
    blocks = EachProcessor.extract_each_blocks(source)
    row = EachRowCompiler.compile(EachProcessor.roots(blocks).first, parser)

    row.key_expression.should eq(%Q{group["id"]})
    row.span.not_nil!.file.should eq("lib/keyed_rows.rb")
    row.span.not_nil!.line.should eq(2)
    child = row.children.first
    child.key_expression.should eq(%Q{item["id"]})
    child.span.not_nil!.file.should eq("lib/keyed_rows.rb")
  end

  it "keeps row text ordinary unless Mochi.raw wraps it" do
    row = compile_row_template(%Q{
      {each @items as item}
        <li>{item[:label]}</li>
        <li>Status {Mochi.raw(item[:svg])} and {item[:note]}</li>
      {end}
    })

    row.bindings.map(&.kind).should eq(["text", "html", "text"])
    row.bindings.map(&.trusted_markup).should eq([false, true, false])
    row.bindings.map(&.expression).should eq([
      %Q{item[:label]},
      %Q{item[:svg]},
      %Q{item[:note]},
    ])
  end

  it "rejects Mochi.raw in row attributes" do
    expect_raises(TemplateExpressionError, "Mochi.raw is only supported in text content") do
      compile_row_template(%Q{
        {each @items as item}
          <li title="{Mochi.raw(item[:title])}">row</li>
        {end}
      })
    end
  end

  it "rejects leftover control blocks inside a row" do
    expect_raises(TemplateExpressionError, /invalid Ruby expression/) do
      compile_row_template(%Q{
        {each @items as item}
          <div>{if item[:active]}on{end}</div>
        {end}
      })
    end
  end
end
