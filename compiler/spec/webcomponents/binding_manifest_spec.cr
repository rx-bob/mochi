require "spec"
require "../../src/webcomponents/binding_manifest"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/ruby_understander"

describe "Binding manifest" do
  it "builds MyCounter bindings and rewrites Ruby without html or css methods" do
    source = <<-RUBY
class MyCounter
  @tag_name = "my-counter"
  @count

  def initialize
    @count = 0
  end

  def html
    %Q{<h1>Count: {@count}</h1><button onclick="{increment}">Increment</button>}
  end

  def css
    %Q{h1 { color: red; }}
  end

  def increment
    @count += 1
  end
end
RUBY

    methods = RubyUnderstander.extract_method_bodies(source, "MyCounter")
    html = RubyUnderstander.extract_raw_string_from_def_body(methods["html"].body, "html")
    css = RubyUnderstander.extract_raw_string_from_def_body(methods["css"].body, "css")

    manifest = ComponentGenerator.new.generate("MyCounter", "my-counter", css, html)

    manifest.bindings.size.should eq(1)
    binding = manifest.bindings.first
    binding.id.should eq(0)
    binding.path.should eq([0, 0])
    binding.kind.should eq("text")
    binding.getter_sym.should eq("__mochi_bind_0")

    manifest.events.size.should eq(1)
    manifest.events.first.method_sym.should eq("increment")
    manifest.html_template.should contain(%(data-mochi-click="increment"))
    manifest.html_template.should_not contain("onclick=")

    rewritten = ComponentGenerator.new.rewrite_ruby(
      source,
      "MyCounter",
      manifest,
      methods
    )

    rewritten.should contain("def __mochi_bind_0; @count; end")
    rewritten.should_not contain("def html")
    rewritten.should_not contain("def css")
    rewritten.should contain("def increment")
  end

  it "generates method-call getters for bare bindings and ivar getters for @ bindings" do
    source = <<-RUBY
class MochiBox
  @tag_name = "mochi-box"
  @label = "box"
  @flag = false

  def html
    %Q{<div class="{box_class}">{@label}</div>}
  end

  def box_class
    @flag ? "on" : "off"
  end
end
RUBY

    methods = RubyUnderstander.extract_method_bodies(source, "MochiBox")
    html = RubyUnderstander.extract_raw_string_from_def_body(methods["html"].body, "html")
    manifest = ComponentGenerator.new.generate("MochiBox", "mochi-box", "", html)

    class_binding = manifest.bindings.find! { |binding| binding.kind == "attr" && binding.attr_name == "class" }
    class_binding.getter_expr.should eq("box_class")

    text_binding = manifest.bindings.find! { |binding| binding.kind == "html" }
    text_binding.getter_expr.should eq("@label")

    rewritten = ComponentGenerator.new.rewrite_ruby(source, "MochiBox", manifest, methods)
    rewritten.should contain("def __mochi_bind_0; box_class; end")
    rewritten.should contain("def __mochi_bind_1; @label; end")
    rewritten.should contain("def box_class")
  end

  it "keeps argument-bearing, nested, and class helper calls in generated getters" do
    source = <<-RUBY
class HelperProbe
  @tag_name = "helper-probe"
  @total

  def html
    %Q{
      <p>{number(@total)}</p>
      <p>{wrap(number(@total), " nested")}</p>
      <p>{total_label}</p>
      <p>{MathHelper.scaled(@total, 2)}</p>
    }
  end

  def number(value)
    value.to_s
  end

  def wrap(value, suffix)
    value + suffix
  end

  def total_label
    compact(@total)
  end

  def compact(value)
    value.to_s + " total"
  end
end
RUBY

    methods = RubyUnderstander.extract_method_bodies(source, "HelperProbe")
    html = RubyUnderstander.extract_raw_string_from_def_body(methods["html"].body, "html")
    manifest = ComponentGenerator.new.generate("HelperProbe", "helper-probe", "", html)

    manifest.bindings.map(&.getter_expr).should eq([
      "number(@total)",
      %Q{wrap(number(@total), " nested")},
      "total_label",
      "MathHelper.scaled(@total, 2)",
    ])

    rewritten = ComponentGenerator.new.rewrite_ruby(source, "HelperProbe", manifest, methods)
    rewritten.should contain("def __mochi_bind_0; number(@total); end")
    rewritten.should contain(%Q{def __mochi_bind_1; wrap(number(@total), " nested"); end})
    rewritten.should contain("def __mochi_bind_2; total_label; end")
    rewritten.should contain("def __mochi_bind_3; MathHelper.scaled(@total, 2); end")
    rewritten.should contain("def compact(value)")
  end

  it "keeps template text for conditionals and lists" do
    descriptor = BindingDescriptor.new(
      4,
      [0, 1],
      "cond",
      "__mochi_bind_4",
      nil,
      "<p>High</p>",
      "@count > 5"
    )

    descriptor.template_text.should eq("<p>High</p>")
    RubyBindingRewriter.expression_for(descriptor).should eq("@count > 5")
  end

  it "injects getters when html and css are the only methods" do
    source = <<-RUBY
class BareCounter
  @tag_name = "bare-counter"

  def html
    %Q{<p>{@count}</p>}
  end

  def css
    %Q{}
  end
end
RUBY

    methods = RubyUnderstander.extract_method_bodies(source, "BareCounter")
    manifest = ComponentGenerator.new.generate(
      "BareCounter",
      "bare-counter",
      "",
      %Q{<p>{@count}</p>}
    )

    rewritten = ComponentGenerator.new.rewrite_ruby(source, "BareCounter", manifest, methods)

    rewritten.should contain("def __mochi_bind_0; @count; end")
    rewritten.should_not contain("def html")
    rewritten.should_not contain("def css")
    rewritten.lines.last.strip.should eq("end")
  end

  it "injects two-way setters that write normalized event fields" do
    source = <<-RUBY
class BindBox
  @tag_name = "bind-box"
  @query
  @enabled

  def initialize
    @query = ""
    @enabled = false
  end

  def html
    %Q{<input bind:value="{@query}"><input type="checkbox" bind:checked="{@enabled}">}
  end

  def css
    %Q{}
  end
end
RUBY

    methods = RubyUnderstander.extract_method_bodies(source, "BindBox")
    html = RubyUnderstander.extract_raw_string_from_def_body(methods["html"].body, "html")
    manifest = ComponentGenerator.new.generate("BindBox", "bind-box", "", html)
    rewritten = ComponentGenerator.new.rewrite_ruby(source, "BindBox", manifest, methods)

    rewritten.should contain("def __mochi_bind_0; @query; end")
    rewritten.should contain("def __mochi_set_query(event); @query = event[:value]; end")
    rewritten.should contain("def __mochi_bind_1; @enabled; end")
    rewritten.should contain("def __mochi_set_enabled(event); @enabled = event[:checked]; end")
    rewritten.should_not contain("def html")
    rewritten.should_not contain("def css")
  end
end
