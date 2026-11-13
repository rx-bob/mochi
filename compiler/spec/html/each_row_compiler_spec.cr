require "spec"
require "../../src/html/each_row_compiler"

private def compile_row_template(
  html : String,
  context : EachRowDomContext = EachRowDomContext.new,
) : EachRowTemplate
  blocks = EachProcessor.extract_each_blocks(html)
  roots = EachProcessor.roots(blocks)
  roots.size.should eq(1)
  EachRowCompiler.compile(roots.first, TemplateExpressionParser.new, context)
end

describe EachRowCompiler do
  it "keeps nested loop scopes distinct and compiles events with row arguments" do
    row = compile_row_template(%(
      <ul>
        {each @events as ev, idx}
          <li data-id="{ev["id"]}">
            {each ev["children"] as child, ci}
              <button class="child" title="{child}-{ev["id"]}" onclick="{pick(ev["id"], child, ci)}">{label(ev, idx)}</button>
            {end}
          </li>
        {end}
      </ul>
    ))

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

  it "marks child component events inside list rows" do
    row = compile_row_template(%Q{
      {each @rows as row}
        <event-row on:select="{pick($event)}"></event-row>
      {end}
    })

    event = row.events.first
    event.event.should eq("select")
    event.component.should be_true
    event.handler.should eq("pick")
    event.args.map(&.kind).should eq(["event"])
    row.template.should contain(%Q{data-mochi-select="__mochi_each_0_ev_1"})
    row.template.should_not contain("on:select")
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

  it "classifies row attribute slots as boolean or textual" do
    row = compile_row_template(%Q{
      {each @items as item}
        <li class="box {item[:kind]}" hidden="{item[:hidden]}" aria-expanded="{item[:expanded]}" data-count="{item[:count]}">{item[:label]}</li>
      {end}
    })

    kind_for = ->(name : String) do
      row.bindings.find! { |binding| binding.attr_name == name }.attr_kind
    end

    kind_for.call("class").should eq("text")
    kind_for.call("hidden").should eq("boolean")
    kind_for.call("aria-expanded").should eq("text")
    kind_for.call("data-count").should eq("text")
  end

  it "keeps conditional and hash class helpers in lexical row scope" do
    row = compile_row_template(%(
      {each @rows as row, idx}
        <button class="item {if row['active']}active {row['label']}{else}inactive{end}"
                data-classes={{ "enabled" => row['active'], "zero" => idx == 0 }}>
          {row['label']}
        </button>
      {end}
    ))

    row.attribute_conditionals.size.should eq(1)
    row.attribute_conditionals.first.original_string.should contain("row['active']")
    row.attribute_hashes.size.should eq(1)
    row.bindings.map(&.expression).should contain("__mochi_each_0_attr_cond_0(row, idx)")
    row.bindings.map(&.expression).should contain("__mochi_each_0_attr_hash_0(row, idx)")
    row.template.should_not contain("{if ")
    row.template.should_not contain("{{")
  end

  it "gives an explicit unsupported diagnostic for with inside a row" do
    source = %Q{
      {each @rows as row}
        {with row[:profile] as profile}<span>{profile[:name]}</span>{end}
      {end}
    }
    parser = TemplateExpressionParser.new(TemplateSourceLocator.new(source, "views/rows.rb"))
    blocks = EachProcessor.extract_each_blocks(source)

    expect_raises(TemplateExpressionError, "Ruby helper method") do
      EachRowCompiler.compile(EachProcessor.roots(blocks).first, parser)
    end
  end

  it "classifies table and option row slots in their authored parent context" do
    table_row = compile_row_template(%Q{
      {each @rows as row}
        <tr data-id="{row["id"]}"><td>{row["label"]}</td><th>{row["label"]}</th></tr>
      {end}
    }, EachRowDomContext.new("tbody", "html"))

    table_row.context_tag.should eq("tbody")
    table_row.context_namespace.should eq("html")
    table_row.bindings.map(&.kind).should eq(["attr", "text", "text"])
    table_row.bindings.map(&.attr_name).should eq(["data-id", nil, nil])

    options = compile_row_template(%Q{
      {each @rows as row}
        <option value="{row["id"]}">{row["label"]}</option>
      {end}
    }, EachRowDomContext.new("select", "html"))

    options.bindings.map(&.kind).should eq(["attr", "text"])
    options.bindings.first.attr_name.should eq("value")
  end

  it "classifies SVG row slots in the SVG namespace" do
    row = compile_row_template(%Q{
      {each @rows as row}
        <g><path data-id="{row["id"]}" fill="{row["color"]}"></path><text>{row["label"]}</text></g>
      {end}
    }, EachRowDomContext.new("g", "svg"))

    row.context_tag.should eq("g")
    row.context_namespace.should eq("svg")
    row.bindings.map(&.kind).should eq(["attr", "attr", "text"])
    row.bindings.map(&.attr_name).should eq(["data-id", "fill", nil])
  end

  it "derives nested row context from the nested loop's actual parent" do
    row = compile_row_template(%Q{
      {each @groups as group}
        <table><tbody>
          {each group["rows"] as row}
            <tr><td>{row["label"]}</td></tr>
          {end}
        </tbody></table>
      {end}
    }, EachRowDomContext.new("div", "html"))

    row.children.size.should eq(1)
    row.children.first.context_tag.should eq("tbody")
    row.children.first.bindings.map(&.kind).should eq(["text"])
  end

  it "reports a source-located error when context parsing loses a row slot" do
    source = %Q{
      {each @rows as row}
        <td>{row["label"]}</td>
      {end}
    }
    parser = TemplateExpressionParser.new(TemplateSourceLocator.new(source, "views/table.rb"))
    blocks = EachProcessor.extract_each_blocks(source)

    error = expect_raises(TemplateExpressionError, "cannot be a row root") do
      EachRowCompiler.compile(EachProcessor.roots(blocks).first, parser, EachRowDomContext.new("tbody", "html"))
    end
    error.span.not_nil!.file.should eq("views/table.rb")
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

  it "lowers conditional branches with the enclosing row scope" do
    row = compile_row_template(%Q{
        {each @items as item}
          <div>{if item[:active]}{item[:label]}{else}off{end}</div>
        {end}
      })
    row.template.should contain("<!--mochi-cond-")
    row.conditionals.size.should eq(1)
    conditional = row.conditionals.first
    conditional.conditions.should eq(["item[:active]", nil])
    conditional.branches.first.scope.should eq(row.scope)
    conditional.branches.first.bindings.first.expression.should eq("item[:label]")
    conditional.branches.last.template.should eq("off")
  end
end
