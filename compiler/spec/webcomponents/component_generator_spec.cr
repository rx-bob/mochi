require "spec"
require "lexbor"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/ruby_understander"
require "../code_test_utils"

describe ComponentGenerator do
  it "builds a static manifest with child-node paths and event attributes" do
    html = %(<h1>Count: {@count}</h1><button onclick="{increment}">Increment</button>)
    gen = ComponentGenerator.new

    manifest = gen.generate("TestCmp", "test-cmp", "h1 { color: red; }", html)

    manifest.tag_name.should eq("test-cmp")
    manifest.class_name.should eq("TestCmp")
    manifest.chi_file.should eq("test-cmp.chi")
    manifest.html_template.should contain("<h1>Count: {@count}</h1>")
    manifest.html_template.should contain(%(data-mochi-click="increment"))
    manifest.html_template.should_not contain("onclick=")
    manifest.css.should eq("h1 { color: red; }")

    manifest.bindings.size.should eq(1)
    binding = manifest.bindings.first
    binding.id.should eq(0)
    binding.path.should eq([0, 0])
    binding.kind.should eq("text")
    binding.template_text.should eq("Count: {@count}")
    binding.getter_expr.should eq("@count")
    binding.getter_sym.should eq("__mochi_bind_0")

    manifest.events.size.should eq(1)
    event = manifest.events.first
    event.path.should eq([1])
    event.event.should eq("click")
    event.method_sym.should eq("increment")
  end

  it "uses method calls for bare text bindings" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      "<div>{rendered_svg}</div>"
    )

    binding = manifest.bindings.first
    binding.kind.should eq("html")
    binding.path.should eq([0, 0])
    binding.getter_expr.should eq("rendered_svg")
  end

  it "uses direct ivar reads for explicit text bindings" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      "<div>{@rendered_svg}</div>"
    )

    binding = manifest.bindings.first
    binding.kind.should eq("html")
    binding.getter_expr.should eq("@rendered_svg")
  end

  it "uses method calls for bare attribute bindings" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      %(<div class="{box_class}">Box</div>)
    )

    binding = manifest.bindings.first
    binding.kind.should eq("attr")
    binding.attr_name.should eq("class")
    binding.getter_expr.should eq("box_class")
  end

  it "records attribute bindings without leaving bind prefixes in the template" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      %(<a bind:href="{@url}">Link</a>)
    )

    binding = manifest.bindings.first
    binding.kind.should eq("attr")
    binding.attr_name.should eq("href")
    binding.path.should eq([0])
    manifest.html_template.should contain(%(href="{@url}"))
    manifest.html_template.should_not contain("bind:")
  end

  it "records conditional and each anchors as bindings" do
    conditionals = ConditionalProcessor.extract_conditionals(
      %(<div>{if @enabled}<p>On</p>{end}</div>)
    )
    each_blocks = EachProcessor.extract_each_blocks(
      %(<ul>{each @items as item}<li>{item}</li>{end}</ul>)
    )
    html = %(<div><!--if-anchor-0--><ul><!--each-anchor-0--></ul></div>)

    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      html,
      "[]",
      {} of String => String,
      conditionals,
      each_blocks
    )

    cond = manifest.bindings.find! { |binding| binding.kind == "cond" }
    cond.getter_expr.should eq("__mochi_cond_0")
    cond.template_text.not_nil!.should contain("<p>On</p>")
    cond.branches.size.should eq(1)
    cond.branches.first.html_template.should contain("<p>On</p>")

    each = manifest.bindings.find! { |binding| binding.kind == "each" }
    each.getter_expr.should eq("@items")
    each.template_text.not_nil!.should contain("<li>")
  end

  it "compiles if/elsif/else branch templates with bindings and events" do
    html = %(<div>{if @a}<span class="{@cls}">{@label}</span><button onclick="{save}">Save</button>{elsif @b}<p>{@other}</p>{else}<em>none</em>{end}</div>)
    conditionals = ConditionalProcessor.extract_conditionals(html)
    template = ConditionalProcessor.process(html).html

    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      template,
      "[]",
      {} of String => String,
      conditionals,
      [] of EachBlock,
      ["save"]
    )

    cond = manifest.bindings.find! { |binding| binding.kind == "cond" }
    cond.getter_expr.should eq("__mochi_cond_0")
    cond.branches.size.should eq(3)

    first = cond.branches[0]
    first.html_template.should contain("data-mochi-click=\"save\"")
    first.bindings.map(&.getter_expr).should contain("@cls")
    first.bindings.map(&.getter_expr).should contain("@label")
    first.events.size.should eq(1)
    first.events.first.path.should eq([1])
    first.events.first.method_sym.should eq("save")

    second = cond.branches[1]
    second.bindings.map(&.getter_expr).should contain("@other")
    second.events.should be_empty

    third = cond.branches[2]
    third.bindings.should be_empty
    third.html_template.should contain("<em>none</em>")

    ids = manifest.all_bindings.map(&.id)
    ids.uniq.size.should eq(ids.size)
  end

  it "discovers each blocks inside conditional branches" do
    html = %(<div>{if @show}<ul>{each @items as item}<li>{item}</li>{end}</ul>{end}</div>)
    conditionals = ConditionalProcessor.extract_conditionals(html)
    template = ConditionalProcessor.process(html).html

    generator = ComponentGenerator.new
    manifest = generator.generate(
      "TestCmp",
      "test-cmp",
      "",
      template,
      "[]",
      {} of String => String,
      conditionals
    )

    cond = manifest.bindings.find! { |binding| binding.kind == "cond" }
    branch = cond.branches.first
    branch.html_template.should contain("<!--each-anchor-0-->")

    each = branch.bindings.find! { |binding| binding.kind == "each" }
    each.getter_expr.should eq("@items")
    generator.each_blocks.size.should eq(1)
    generator.each_blocks.first.loop_def.array_name.should eq("@items")
  end

  it "recursively compiles conditionals nested inside branches" do
    html = %(<div>{if @outer}<p>{@label}</p>{if @inner}<span>{@nested}</span>{end}{elsif @other}<em>other</em>{end}</div>)
    conditionals = ConditionalProcessor.extract_conditionals(html)
    template = ConditionalProcessor.process(html).html

    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      template,
      "[]",
      {} of String => String,
      conditionals
    )

    outer = manifest.bindings.find! { |binding| binding.kind == "cond" }
    outer.branches.size.should eq(2)
    outer_branch = outer.branches[0]
    outer_branch.html_template.should contain("<!--if-anchor-1-->")
    outer_branch.bindings.map(&.getter_expr).should contain("@label")

    nested = outer_branch.bindings.find! { |binding| binding.kind == "cond" }
    nested.getter_expr.should eq("__mochi_cond_1")
    nested.branches.size.should eq(1)
    nested.branches.first.html_template.should contain("<span>{@nested}</span>")
    nested.branches.first.bindings.map(&.getter_expr).should contain("@nested")
  end

  it "recursively compiles three levels of conditional branches" do
    html = %(<div>{if @a}A{if @b}B{if @c}<span>{@value}</span>{end}{end}{end}</div>)
    conditionals = ConditionalProcessor.extract_conditionals(html)
    template = ConditionalProcessor.process(html).html

    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      template,
      "[]",
      {} of String => String,
      conditionals
    )

    level_one = manifest.bindings.find! { |binding| binding.kind == "cond" }
    level_one_branch = level_one.branches.first
    level_one_branch.html_template.should contain("<!--if-anchor-1-->")

    level_two = level_one_branch.bindings.find! { |binding| binding.kind == "cond" }
    level_two_branch = level_two.branches.first
    level_two_branch.html_template.should contain("<!--if-anchor-2-->")

    level_three = level_two_branch.bindings.find! { |binding| binding.kind == "cond" }
    level_three_branch = level_three.branches.first
    level_three_branch.html_template.should contain("<span>{@value}</span>")
    level_three_branch.bindings.map(&.getter_expr).should contain("@value")

    ids = manifest.all_bindings.map(&.id)
    ids.uniq.size.should eq(ids.size)
  end
end
