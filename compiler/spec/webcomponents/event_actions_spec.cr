require "spec"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/ruby_understander"
require "../../src/ruby/each_method_generator"

describe "Bound event actions" do
  it "retains ordered setter and callback independently of attribute order" do
    [false, true].each do |reverse|
      [{"input", "value", "input"}, {"input", "checked", "change"}, {"select", "value", "change"}].each do |tag, property, event|
        attributes = [%(bind:#{property}="{@draft}"), %(on#{event}.prevent.stop="{observe(@draft, $event)}")]
        attributes.reverse! if reverse
        html = EventArgumentExtractor.process("<#{tag} #{attributes.join(" ")}></#{tag}>")
        manifest = ComponentGenerator.new.generate("Form", "test-form", "", html, method_names: ["observe"])
        manifest.events.size.should eq(1)
        descriptor = manifest.events.first
        descriptor.actions.map(&.kind).should eq(["set", "call"])
        descriptor.actions.map(&.target).should eq(["@draft", "observe"])
        descriptor.actions.first.property.should eq(property)
        descriptor.modifiers.should eq(["prevent", "stop"])
        descriptor.event.should eq(event)
        manifest.html_template.should contain(%(data-mochi-#{event}="__mochi_action_0"))
        manifest.html_template.should_not contain("data-mochi-args-")
        manifest.bindings.count { |binding| binding.kind == "expr" }.should eq(0)
      end
    end
  end

  it "validates original handlers even when a wrapper is generated" do
    expect_raises(Exception, "undefined event handler") do
      ComponentGenerator.new.generate("Form", "test-form", "", %(<input bind:value="{@draft}" oninput="{missing}">), method_names: ["initialize"])
    end
  end

  it "executes arguments after the setter and stops on setter failure" do
    source = <<-'RUBY'
class Form
  def initialize
    @draft = "old"
    @calls = []
  end
  def observe(value, event)
    @calls.push([value, @draft, event[:value]])
  end
  def implicit(event)
    @calls.push(event[:value])
  end
  def optional(event = nil)
    @calls.push(event)
  end
  def rest(*args)
    @calls.push(args)
  end
  def result
    [@draft, @calls]
  end
end
RUBY
    methods = RubyUnderstander.extract_method_bodies(source, "Form")
    html = EventArgumentExtractor.process(%(<input bind:value="{@draft}" oninput="{observe(@draft, $event)}"><input oninput="{implicit}" bind:value="{@draft}"><input bind:value="{@draft}" oninput="{optional}"><input bind:value="{@draft}" oninput="{rest}">))
    generator = ComponentGenerator.new
    manifest = generator.generate("Form", "test-form", "", html)
    rewritten = generator.rewrite_ruby(source, "Form", manifest, methods)
    output = IO::Memory.new
    errors = IO::Memory.new
    program = rewritten + "\n" + <<-'RUBY'
form = Form.new
form.__mochi_action_0(value: "fresh")
form.__mochi_action_1(value: "implicit")
form.__mochi_action_2(value: "optional")
form.__mochi_action_3(value: "rest")
failed_event = Object.new
def failed_event.[](key); raise "setter failed"; end
begin
  form.__mochi_action_0(failed_event)
rescue => error
  puts error.message
end
p form.result
RUBY
    Process.run("ruby", ["-e", program], output: output, error: errors).success?.should be_true, errors.to_s
    output.to_s.should eq("setter failed\n[\"rest\", [[\"fresh\", \"fresh\", \"fresh\"], \"implicit\", nil, []]]\n")
  end

  it "preserves literal Ruby interpolation markers and leading required arity" do
    literal = EventActionGenerator.ruby_argument(EventArgumentDescriptor.literal_string(%q(#@draft #{danger})))
    output = IO::Memory.new
    Process.run("ruby", ["-e", "@draft = 'bad'; puts #{literal}"], output: output).success?.should be_true
    output.to_s.should eq(%q(#@draft #{danger}) + "\n")
    source = "class Form; def leading(event, optional = nil); end; def trailing(*rest, event); end; def optional_then_required(optional = nil, event); end; end"
    arities = EventActionGenerator.required_arguments(RubyUnderstander.extract_method_bodies(source, "Form"))
    arities.should eq({"leading" => 1, "trailing" => 0, "optional_then_required" => 0})
  end

  it "composes row actions with current lexical arguments and property slots" do
    html = EventArgumentExtractor.process(%({each @rows as row, idx}<input oninput="{observe(row, idx, @draft)}" bind:value="{@draft}"><input type="checkbox" bind:checked="{@flag}"><select bind:value="{@draft}" onchange="{changed}"><option>a</option></select>{end}))
    row = EachRowCompiler.compile(EachProcessor.extract_each_blocks(html).first, TemplateExpressionParser.new)
    row.bindings.map(&.kind).should eq(["prop", "prop", "prop"])
    row.template.should_not contain("bind:")
    row.template.should_not contain("data-mochi-bind-")
    row.events.map(&.event).should eq(["input", "change", "change"])
    row.events.map { |event| event.actions.map(&.kind) }.should eq([["set", "call"], ["set"], ["set", "call"]])
    code = EachMethodGenerator.generate_event_wrapper(row.events.first)
    code.should contain("row = __mochi_scope_0_item")
    code.should contain("idx = __mochi_scope_0_index")
    code.should contain("@draft = __event[:value]\n    observe(row, idx, @draft)")
  end
end
