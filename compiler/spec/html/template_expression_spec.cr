require "spec"
require "../../src/html/template_expression"

describe TemplateExpressionParser do
  it "balances Ruby strings, interpolation, percent literals and adjacent hashes" do
    [
      %q(@field["label"]),
      %q(@field['label']),
      %q(format({"a" => {"b" => "}"}})),
      %q("#{@field["label"]}:#{wrap("}")}"),
      %q("escaped \"quote\" and }"),
      %q(%Q|#{@field["label"]} and }|),
      %q(%q[a"b\]c]),
      %q("{if @wrong}{each @wrong as wrong}{end}"),
      %q(@field["&quot;<tag>&"]),
    ].each do |source|
      template = %(<p title="{#{source}}">{#{source}}</p>)
      expressions = TemplateExpressionParser.new.scan(template, "attribute")
      expressions.map(&.source).should eq([source, source])
      expressions.each { |expression| expression.full_text(template).should eq("{#{source}}") }
    end
  end

  it "escapes literal braces without changing braces inside Ruby" do
    source = %q(<p title="{format({"a" => {"b" => 1}})}">{{literal}} {"{{text}}"}</p>)
    escaped = TemplateExpressionParser.escape_literal_braces(source)
    escaped.should contain("\uE000literal\uE001")
    expressions = TemplateExpressionParser.new.scan(escaped, "template")
    expressions.map(&.source).should eq([%q(format({"a" => {"b" => 1}})), %q("{{text}}")])
  end

  it "reports authored locations for unclosed strings, interpolation and malformed delimiters" do
    [%q(<p title="{@field["label]}"/>), %q(<p title="{"#{@field["label"]}"/>),
     %q(<p title="{format([1, 2)}"/>)].each do |template|
      source = "class Form\n  def html\n    %Q{\n#{template}\n}\nend\nend"
      parser = TemplateExpressionParser.new(TemplateSourceLocator.new(source, "lib/Form.rb"))
      error = expect_raises(TemplateExpressionError) { parser.scan(template, "attribute") }
      error.message.to_s.should contain("lib/Form.rb:4:")
      error.message.to_s.should match(/unclosed template placeholder|invalid Ruby expression/)
    end
  end

  it "keeps nested calls, hash arguments, and quoted braces in one expression" do
    template = %q(<p>{format(@h["key"], {a: 1})} and {wrap(number(@total), "}")}</p>)
    expressions = TemplateExpressionParser.new.scan(template, "text")

    expressions.map(&.source).should eq([
      %q(format(@h["key"], {a: 1})),
      %q(wrap(number(@total), "}")),
    ])
    expressions[0].template_start.should eq(template.index("{format").not_nil!)
    expressions[0].template_end.should eq(template.index("} and").not_nil! + 1)
  end

  it "records byte ranges after multibyte text and literal brace escapes" do
    template = "café \uE000literal\uE001 and {format(@h[\"k\"], \"}\")}"
    expressions = TemplateExpressionParser.new.scan(template, "text")

    expressions.size.should eq(1)
    expressions[0].source.should eq(%q(format(@h["k"], "}")))
    expressions[0].template_start.should eq(template.byte_index("{format").not_nil!)
    expressions[0].template_end.should eq(template.bytesize)
  end

  it "splits nested event arguments without splitting quoted commas" do
    parser = TemplateExpressionParser.new
    method_name, arguments = parser.parse_call(%q(select_row('tr_9f2a', format(1, 2), 'a,b')))
    method_name.should eq("select_row")
    arguments.should eq([%q('tr_9f2a'), "format(1, 2)", %q('a,b')])
  end

  it "reports the original file line and column for a malformed expression" do
    source = <<-RUBY
class Screen
  def html
    %Q{
      <p>{@count > }</p>
    }
  end
end
RUBY
    locator = TemplateSourceLocator.new(source, "lib/screen.rb")
    error = expect_raises(TemplateExpressionError) do
      TemplateExpressionParser.new(locator).scan("<p>{@count > }</p>", "text")
    end
    error.message.not_nil!.should contain("lib/screen.rb:4:")
    error.message.not_nil!.should contain("invalid Ruby expression")
  end

  it "rejects backticks, assignments, and blocks at build time" do
    parser = TemplateExpressionParser.new
    [
      "`window.alert(1)`",
      "@count = 1",
      "items.map { |item| item.name }",
    ].each do |expression|
      expect_raises(TemplateExpressionError) do
        parser.scan("{#{expression}}", "text")
      end
    end
  end

  it "requires Mochi.raw to wrap the whole expression" do
    error = expect_raises(TemplateExpressionError) do
      TemplateExpressionParser.new.scan(%q(<p>{"prefix " + Mochi.raw(@icon)}</p>), "text")
    end
    error.message.not_nil!.should contain("Mochi.raw must wrap the entire template expression")
  end

  it "rejects an unclosed placeholder after a quoted brace" do
    error = expect_raises(TemplateExpressionError) do
      TemplateExpressionParser.new.scan(%q(<p>{wrap("}")</p>), "text")
    end
    error.message.not_nil!.should contain("unclosed template placeholder")
  end

  it "rejects Ruby string interpolation instead of reading it as a placeholder" do
    error = expect_raises(TemplateExpressionError) do
      TemplateExpressionParser.new.scan(%q(<p>#{@count}</p>), "text")
    end
    error.message.not_nil!.should contain("string interpolation")
  end
end
