# typed: false
require_relative "../test_helper"
require_relative "../../src/data_models/web_component"

class WebComponentTest < Minitest::Test
  def test_construction
    wc = WebComponent.new(
      name: "FooWebComp",
      js_code: "class Foo {}"
    )
    assert_equal "FooWebComp", wc.name
    assert_equal "class Foo {}", wc.js_code
  end

  def test_with_empty_js_code
    wc = WebComponent.new(name: "EmptyComp", js_code: "")
    assert_equal "EmptyComp", wc.name
    assert_equal "", wc.js_code
  end
end
