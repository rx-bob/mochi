# typed: false
require_relative "../test_helper"
require_relative "../../src/data_models/ruby_var"

class RubyVariableTest < Minitest::Test
  def test_construction
    rv = RubyVariable.new(value: "hello", exported: true)
    assert_equal "hello", rv.value
    assert_equal true, rv.exported
  end

  def test_not_exported
    rv = RubyVariable.new(value: "world", exported: false)
    assert_equal "world", rv.value
    assert_equal false, rv.exported
  end
end
