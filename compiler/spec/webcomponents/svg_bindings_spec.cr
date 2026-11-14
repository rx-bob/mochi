require "spec"
require "../../src/webcomponents/component_generator"

describe ComponentGenerator do
  it "keeps dynamic SVG attributes inert without changing binding names or HTML descendants" do
    html = %q(<svg viewBox="0 0 {@width} 100"><path d="{@path}" transform="translate({@x} {@y})" stroke-width="{@stroke}"></path><foreignObject x="{@x}"><div title="{@title}">HTML</div></foreignObject></svg>)
    manifest = ComponentGenerator.new.generate("SvgRoot", "svg-root", "", html)

    manifest.html_template.should contain(%(data-mochi-svg-viewbox="0 0 {@width} 100"))
    manifest.html_template.should contain(%(data-mochi-svg-d="{@path}"))
    manifest.html_template.should contain(%(data-mochi-svg-transform="translate({@x} {@y})"))
    manifest.html_template.should contain(%(data-mochi-svg-stroke-width="{@stroke}"))
    manifest.html_template.should contain(%(data-mochi-svg-x="{@x}"))
    manifest.html_template.should contain(%(<div title="{@title}">))
    manifest.html_template.should_not contain(%( d="{@path}"))
    manifest.bindings.map(&.attr_name).should eq(["viewBox", "d", "transform", "transform", "stroke-width", "x", "title"])
    manifest.bindings.select { |binding| binding.attr_name == "transform" }.map(&.template_text).should eq(["translate({@x} {@y})", "translate({@x} {@y})"])
  end

  it "also defers geometry in conditional SVG branches" do
    source = %q(<svg>{if @open}<path d="{@path}" transform="translate({@x} {@y})"></path>{end}</svg>)
    conditionals = ConditionalProcessor.extract_conditionals(source)
    manifest = ComponentGenerator.new.generate("SvgRoot", "svg-root", "", ConditionalProcessor.process(source).html,
      conditionals: conditionals)
    branch = manifest.bindings.find! { |binding| binding.kind == "cond" }.branches.first
    branch.html_template.should contain(%(data-mochi-svg-d="{@path}"))
    branch.html_template.should contain(%(data-mochi-svg-transform="translate({@x} {@y})"))
    branch.bindings.map(&.attr_name).should eq(["d", "transform", "transform"])
  end
end
