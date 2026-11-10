require "spec"
require "lexbor"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/ruby_understander"
require "../code_test_utils"

describe ComponentGenerator do
  it "builds a static manifest with child-node paths and event attributes" do
    html = %(<h1>Count: {count}</h1><button onclick="{increment}">Increment</button>)
    gen = ComponentGenerator.new

    manifest = gen.generate("TestCmp", "test-cmp", "h1 { color: red; }", html)

    manifest.tag_name.should eq("test-cmp")
    manifest.class_name.should eq("TestCmp")
    manifest.chi_file.should eq("test-cmp.chi")
    manifest.html_template.should contain("<h1>Count: {count}</h1>")
    manifest.html_template.should contain(%(data-mochi-click="increment"))
    manifest.html_template.should_not contain("onclick=")
    manifest.css.should eq("h1 { color: red; }")

    manifest.bindings.size.should eq(1)
    binding = manifest.bindings.first
    binding.id.should eq(0)
    binding.path.should eq([0, 0])
    binding.kind.should eq("text")
    binding.template_text.should eq("Count: {count}")
    binding.getter_sym.should eq("__mochi_bind_0")

    manifest.events.size.should eq(1)
    event = manifest.events.first
    event.path.should eq([1])
    event.event.should eq("click")
    event.method_sym.should eq("increment")
  end

  it "uses html bindings for pure-variable text nodes" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      "<div>{rendered_svg}</div>"
    )

    binding = manifest.bindings.first
    binding.kind.should eq("html")
    binding.path.should eq([0, 0])
    binding.getter_expr.should eq("@rendered_svg")
  end

  it "records attribute bindings without leaving bind prefixes in the template" do
    manifest = ComponentGenerator.new.generate(
      "TestCmp",
      "test-cmp",
      "",
      %(<a bind:href="{url}">Link</a>)
    )

    binding = manifest.bindings.first
    binding.kind.should eq("attr")
    binding.attr_name.should eq("href")
    binding.path.should eq([0])
    manifest.html_template.should contain(%(href="{url}"))
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
    cond.getter_expr.should eq("@enabled")
    cond.template_text.not_nil!.should contain("<p>On</p>")

    each = manifest.bindings.find! { |binding| binding.kind == "each" }
    each.getter_expr.should eq("@items")
    each.template_text.not_nil!.should contain("<li>")
  end
end
