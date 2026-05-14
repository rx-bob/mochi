# typed: false
require_relative "../test_helper"
require_relative "../../src/webcomponents/component_generator"

class ComponentGeneratorBindingTest < Minitest::Test
  def test_binding_construction
    binding = ComponentGenerator::Binding.new(
      path: [0, 1, 0],
      type: :text,
      value: "{count}",
      name: nil
    )

    assert_equal [0, 1, 0], binding.path
    assert_equal :text, binding.type
    assert_equal "{count}", binding.value
    assert_nil binding.name
  end

  def test_binding_with_attribute_name
    binding = ComponentGenerator::Binding.new(
      path: [0, 1, 0],
      type: :attr,
      value: "{active}",
      name: "class"
    )

    assert_equal "class", binding.name
    assert_equal :attr, binding.type
  end

  def test_binding_type_error_on_wrong_path
    assert_raises(TypeError) do
      ComponentGenerator::Binding.new(path: "wrong", type: :text, value: "{x}", name: nil)
    end
  end
end
