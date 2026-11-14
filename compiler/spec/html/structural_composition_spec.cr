require "spec"
require "../../src/html/each_row_compiler"
require "../../src/ruby/each_method_generator"
require "../../src/webcomponents/component_generator"

private def structural_row(source : String) : EachRowTemplate
  EachRowCompiler.compile(EachProcessor.roots(EachProcessor.extract_each_blocks(source)).first,
    TemplateExpressionParser.new(TemplateSourceLocator.new(source, "lib/Form.rb")))
end

describe "mixed structural fragments" do
  it "keeps nested loop attribute helpers in their own lexical scope" do
    row = structural_row(<<-HTML)
{each @groups as group, gi}{if group[:open]}
{each group[:fields] as field, fi}
<p class="{if field[:active]}active {group[:label]}{else}quiet{end}"
   data-classes={{ "first" => fi == 0 }}>{field[:label]}</p>
{end}{end}{end}
HTML
    row.attribute_conditionals.should be_empty
    row.attribute_hashes.should be_empty
    branch = row.conditionals.first.branches.first
    branch.attribute_conditionals.should be_empty
    child = branch.children.first
    child.attribute_conditionals.size.should eq(1)
    child.attribute_hashes.size.should eq(1)
    child.bindings.map(&.expression).should contain("__mochi_each_#{child.block_id}_attr_cond_0(group, gi, field, fi)")
    child.bindings.map(&.expression).should contain("__mochi_each_#{child.block_id}_attr_hash_0(group, gi, field, fi)")
  end

  it "defers SVG attributes until evaluated values can replace their slots" do
    row = structural_row(%({each @rows as row}<svg><circle r="{row[:radius]}"></circle><foreignObject><input value="{row[:label]}"></foreignObject></svg>{end}))
    document = Lexbor::Parser.new(row.template)
    circle = document.css("circle").first
    circle.attribute_by("r").should be_nil
    deferred = JSON.parse(circle.attribute_by("data-mochi-row-attr-0").not_nil!)
    deferred["name"].as_s.should eq("r")
    deferred["template"].as_s.should eq(EachRowCompiler.sentinel(0))
    document.css("input").first.attribute_by("value").should eq(EachRowCompiler.sentinel(1))
    row.bindings.first.attr_name.should eq("r")
  end

  it "retains scopes through if, each, nested else branches, props, and events" do
    row = structural_row(<<-HTML)
{each @groups as group, gi}
<section>{if group[:open]}
  {each group[:fields] as field, fi}
    {if field[:help]}<field-editor label="{group[:label]}:{field[:label]}" on:edit="{pick(group[:id], field[:id], gi, fi, $event)}"></field-editor>
    {elsif field[:invalid]}<p>{field[:label]}</p>
    {else}{if group[:fallback]}<b>{group[:label]}</b>{else}<i>{field[:label]}</i>{end}{end}
  {end}
{else}<p>{group[:label]}</p>{end}</section>
{end}
HTML
    row.children.should be_empty
    outer = row.conditionals.first
    outer.branches.first.scope.should eq(row.scope)
    field = outer.branches.first.children.first
    field.scope_names.should eq(["group", "gi", "index", "field", "fi"])
    branch = field.conditionals.first.branches.first
    branch.scope.should eq(field.scope)
    branch.events.first.args.size.should eq(5)
    branch.events.first.scope.map(&.item_name).should eq(["group", "field"])
    branch.bindings.map(&.expression).should eq(["group[:label]", "field[:label]"])
    field.conditionals.first.branches.last.conditionals.first.branches.size.should eq(2)
    ids = [] of Int32
    row.each_template { |fragment| ids << fragment.block_id }
    ids.uniq.should eq(ids)
    code = EachMethodGenerator.generate_rows_method(row)
    code.should contain("if (group[:open])")
    code.should contain("elsif (field[:invalid])")
    code.should contain("; field, fi, index|")
    branch.span.not_nil!.file.should eq("lib/Form.rb")
  end

  it "preserves branch insertion contexts under table, select, SVG and foreignObject" do
    source = <<-HTML
<table><tbody>{if @open}{each @rows as row}<tr>{if row[:ok]}<td>{row[:name]}</td>{else}<td>Missing</td>{end}</tr>{end}{else}<tr><td>Closed</td></tr>{end}</tbody></table>
<select>{if @open}{each @rows as row}{if row[:ok]}<option>{row[:name]}</option>{else}<option>Missing</option>{end}{end}{end}</select>
<svg><g>{if @open}{each @rows as row}{if row[:ok]}<circle r="{row[:radius]}"></circle>{end}{end}{end}</g><foreignObject>{each @rows as row}<div>{if row[:ok]}<p>{row[:name]}</p>{end}</div>{end}</foreignObject></svg>
HTML
    conditional = ConditionalProcessor.process(source)
    each = EachProcessor.process(conditional.html)
    generator = ComponentGenerator.new
    manifest = generator.generate("Form", "form-root", "", each.html,
      conditionals: conditional.conditionals, each_blocks: each.each_blocks)
    branches = manifest.bindings.select { |b| b.kind == "cond" }.map(&.branches.first)
    branches.map(&.context_tag).should eq(["tbody", "select", "g"])
    branches.map(&.context_namespace).should eq(["html", "html", "svg"])
    branches.first.html_template.should contain("<!--each-anchor-")
    all = [] of EachRowFragment
    generator.each_row_templates.each { |root| root.each_template { |f| all << f } }
    all.any? { |f| f.context_tag == "tr" && f.template.includes?("<td>") }.should be_true
    all.any? { |f| f.context_tag == "select" && f.template.includes?("<option>") }.should be_true
    all.any? { |f| f.context_namespace == "svg" && f.template.includes?("<circle") }.should be_true
    all.any? { |f| f.context_tag == "div" && f.context_namespace == "html" }.should be_true
  end

  it "reports malformed branch expressions and invalid table fragments at authored locations" do
    source = "{each @rows as row}\n<div>{if row[}<b>Bad</b>{end}</div>\n{end}"
    error = expect_raises(TemplateExpressionError) { structural_row(source) }
    error.message.to_s.should contain("lib/Form.rb:2")
    source = "{each @rows as row}\n<table><tbody>{if row[:ok]}<div>{row[:name]}</div>{end}</tbody></table>\n{end}"
    error = expect_raises(TemplateExpressionError) { structural_row(source) }
    error.message.to_s.should contain("lib/Form.rb:2")
    error.message.to_s.should contain("<tbody>")
  end
end
