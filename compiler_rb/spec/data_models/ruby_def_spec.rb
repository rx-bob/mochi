# typed: false
require_relative "../test_helper"
require_relative "../../src/data_models/ruby_def"

class RubyDefTest < Minitest::Test
  def test_construction_and_field_access
    rd = RubyDef.new(
      name: "foo",
      file_name: "bar.rb",
      class_name: "Bar",
      body: ["line1"],
      parameters: ["a", "b"]
    )

    assert_equal "foo", rd.name
    assert_equal "bar.rb", rd.file_name
    assert_equal "Bar", rd.class_name
    assert_equal ["line1"], rd.body
    assert_equal ["a", "b"], rd.parameters
  end

  def test_nil_name
    rd = RubyDef.new(
      name: nil,
      file_name: "foo.rb",
      class_name: "Foo",
      body: [],
      parameters: []
    )

    assert_nil rd.name
    assert_equal "foo.rb", rd.file_name
    assert_equal "Foo", rd.class_name
    assert_empty rd.body
    assert_empty rd.parameters
  end
end
