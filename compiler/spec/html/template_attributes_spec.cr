require "spec"
require "lexbor"
require "../../src/html/template_attributes"
require "../../src/html/attribute_conditional_extractor"
require "../../src/html/attribute_hash_extractor"
require "../../src/html/event_argument_extractor"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/attribute_method_generator"

describe TemplateAttributes do
  it "distinguishes quoted literal braces from explicit hashes without hiding malformed pairs" do
    html = %q(<p title="{{literal}}" data-flags="{{ "active" => true }}" data-empty="{{}}"></p>)
    result = AttributeHashExtractor.process(html)
    result.hashes.size.should eq(2)
    result.html.should contain(%q(title="{{literal}}"))
    manifest = ComponentGenerator.new.generate("Form", "form-root", "", %q(<p title="{{literal}}">{{text}}</p>))
    manifest.bindings.should be_empty
    node = Lexbor.new(manifest.html_template).css("p").first
    node.attribute_by("title").should eq("{literal}")
    node.inner_text.should eq("{text}")
    [%q(<p class="{{ "active" => }}">), %q(<p class={{literal}}>)].each do |bad|
      expect_raises(TemplateExpressionError) { AttributeHashExtractor.process(bad) }
    end
  end

  it "finds complete attributes without interpreting Ruby quotes as HTML quotes" do
    html = %q(<p title="{@field["label"]}" data-alt='{@field['label']}' data-text="{"#{@field["label"]} > }"}" disabled></p>)
    attributes = TemplateAttributes.scan(html)
    attributes.map(&.name).should eq(["title", "data-alt", "data-text"])
    attributes.map { |attribute| attribute.value(html) }.should eq([
      %q({@field["label"]}), %q({@field['label']}), %q({"#{@field["label"]} > }"}),
    ])
    safe = TemplateExpressionParser.new.html_safe(html)
    node = Lexbor.new(safe).css("p").first
    attributes.each { |attribute| node.attribute_by(attribute.name).should eq(attribute.value(html)) }
    node.attribute_by("disabled").should eq("")
  end

  it "restores expression entities exactly once and preserves literal HTML entities" do
    html = %q(<p title="{@field["&quot;<tag>&"]}" data-literal="&quot; &amp;">{format("<b>&quot;</b>")}</p>)
    manifest = ComponentGenerator.new.generate("Form", "form-root", "", html)
    manifest.bindings.map(&.getter_expr).should contain(%q(@field["&quot;<tag>&"]))
    manifest.bindings.map(&.getter_expr).should contain(%q(format("<b>&quot;</b>")))
    Lexbor.new(manifest.html_template).css("p").first.attribute_by("data-literal").should eq(%q(" &))
  end

  it "ignores fake event attributes and structural directives inside Ruby strings" do
    html = %q(<p title="{"onclick='{wrong}' {if @wrong}{end}"}"></p><button onclick="{pick(@field["label"], "{end}")}">Pick</button>)
    _, events = EventArgumentExtractor.rewrite(html) { |call| call.method_name }
    events.map(&.method_name).should eq(["pick"])
    events.first.arguments.should eq([%q(@field["label"]), %q("{end}")])
    ConditionalProcessor.process(html).conditionals.should be_empty
    EachProcessor.process(%q({each @rows as row}<p>{"{each fake as item}{end}"}</p>{end})).each_blocks.size.should eq(1)
  end

  it "extracts quoted conditional and nested hash attributes with raw Ruby intact" do
    html = %q(<p class="{if @field["active"]}&quot; yes {@field["label"]} &amp; {{literal}}{else}no{end}" data-flags="{{ "one" => @field["active"], "two" => {"nested" => true} }}"></p>)
    hashes = AttributeHashExtractor.process(html)
    hashes.hashes.first.original_string.should contain(%q({"nested" => true}))
    conditions = AttributeConditionalExtractor.process(hashes.html)
    conditions.conditionals.first.original_string.should contain(%q(@field["active"]))
    generated = AttributeMethodGenerator.generate_method(conditions.conditionals.first)
    code = "class Form\n#{generated}\nend\nf=Form.new\nf.instance_variable_set(:@field, {\"active\"=>true, \"label\"=>\"A < B & C\"})\nputs f.__mochi_attr_cond_0\n"
    output = IO::Memory.new
    status = Process.run("ruby", ["-e", code], output: output, error: output)
    status.success?.should be_true
    output.to_s.should eq("\" yes A < B & C & {literal}\n")
  end
end
