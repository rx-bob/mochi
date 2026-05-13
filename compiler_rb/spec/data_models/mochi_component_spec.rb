# typed: false
require_relative "../test_helper"
require_relative "../../src/data_models/mochi_component"

class MochiComponentTest < Minitest::Test
  def test_construction
    wc = WebComponent.new(name: "TestComp", js_code: "class Test {}")

    mc = MochiComponent.new(
      absolute_path: "/test/component.rb",
      name: "TestComponent",
      imports: ["foo", "bar"],
      ruby_code: "class TestComponent\nend",
      web_component: wc,
      html: "<div>hello</div>",
      css: ".red { color: red; }"
    )

    assert_equal "/test/component.rb", mc.absolute_path
    assert_equal "TestComponent", mc.name
    assert_equal ["foo", "bar"], mc.imports
    assert_equal "class TestComponent\nend", mc.ruby_code
    assert_equal wc, mc.web_component
    assert_equal "<div>hello</div>", mc.html
    assert_equal ".red { color: red; }", mc.css
  end

  def test_empty_imports
    wc = WebComponent.new(name: "EmptyComp", js_code: "class Empty {}")

    mc = MochiComponent.new(
      absolute_path: "/tmp/empty.rb",
      name: "EmptyComponent",
      imports: [],
      ruby_code: "",
      web_component: wc,
      html: "",
      css: ""
    )

    assert_empty mc.imports
    assert_equal "", mc.ruby_code
  end
end
