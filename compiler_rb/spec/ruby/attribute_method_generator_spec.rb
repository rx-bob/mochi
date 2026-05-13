# typed: false
require_relative "../test_helper"
require_relative "../../src/html/attribute_conditional_extractor"
require_relative "../../src/ruby/attribute_method_generator"

class AttributeMethodGeneratorTest < Minitest::Test
  def test_generate_method_creates_attribute_conditional_method
    cond = ExtractedAttributeConditional.new(
      id: 0,
      original_string: "{if @active}active{end}",
      attribute_name: "class"
    )

    method_code = AttributeMethodGenerator.generate_method(cond)

    assert_includes method_code, "def __mochi_attr_cond_0"
    assert_includes method_code, "if @active"
    assert_includes method_code, "_res += \"active\""
    assert_includes method_code, "end"
  end

  def test_generate_method_with_mixed_text_and_conditionals
    cond = ExtractedAttributeConditional.new(
      id: 0,
      original_string: "nav-item {if @active}active-{@id}{end}",
      attribute_name: "class"
    )

    method_code = AttributeMethodGenerator.generate_method(cond)

    assert_includes method_code, "def __mochi_attr_cond_0"
    assert_includes method_code, "nav-item "
    assert_includes method_code, "if @active"
    assert_includes method_code, "active-\#{@id}"
    assert_includes method_code, "_res"
  end

  def test_generate_method_converts_braces_to_interpolation
    cond = ExtractedAttributeConditional.new(
      id: 2,
      original_string: "{if @count > 5}high-{count}{end}",
      attribute_name: "class"
    )

    method_code = AttributeMethodGenerator.generate_method(cond)

    assert_includes method_code, "if @count > 5"
    assert_includes method_code, "high-\#{count}"
  end

  def test_generate_method_escapes_quotes
    cond = ExtractedAttributeConditional.new(
      id: 3,
      original_string: '{if @active}data-value="hello"{end}',
      attribute_name: "class"
    )

    method_code = AttributeMethodGenerator.generate_method(cond)

    assert_includes method_code, 'data-value=\\"hello\\"'
  end

  def test_generate_all_methods_returns_empty_string_for_empty_array
    code = AttributeMethodGenerator.generate_all_methods([])
    assert_equal "", code
  end

  def test_generate_all_methods_generates_multiple_methods
    conditionals = [
      ExtractedAttributeConditional.new(id: 0, original_string: "{if @a}a{end}", attribute_name: "class"),
      ExtractedAttributeConditional.new(id: 1, original_string: "{if @b}b{end}", attribute_name: "style")
    ]

    code = AttributeMethodGenerator.generate_all_methods(conditionals)

    assert_includes code, "def __mochi_attr_cond_0"
    assert_includes code, "def __mochi_attr_cond_1"
  end

  def test_inject_methods_into_class_injects_before_class_end
    ruby_code = <<~RUBY
      class Counter
        def initialize
          @count = 0
        end

        def increment
          @count += 1
        end
      end
    RUBY

    conditionals = [
      ExtractedAttributeConditional.new(id: 0, original_string: "{if @active}active{end}", attribute_name: "class")
    ]

    modified = AttributeMethodGenerator.inject_methods_into_class(ruby_code, "Counter", conditionals)

    assert_includes modified, "def __mochi_attr_cond_0"
    assert_includes modified, "if @active"

    attr_method_index = modified.index("def __mochi_attr_cond_0")
    final_end_index = modified.rindex("end")

    assert attr_method_index
    assert final_end_index
    assert_operator attr_method_index, :<, final_end_index
  end

  def test_inject_methods_into_class_returns_unchanged_when_no_conditionals
    ruby_code = "class Test\nend"
    conditionals = []

    modified = AttributeMethodGenerator.inject_methods_into_class(ruby_code, "Test", conditionals)
    assert_equal ruby_code, modified
  end

  def test_inject_methods_into_class_with_multiple_conditionals
    ruby_code = <<~RUBY
      class Test
        def foo
          "bar"
        end
      end
    RUBY

    conditionals = [
      ExtractedAttributeConditional.new(id: 0, original_string: "{if @a}a{end}", attribute_name: "class"),
      ExtractedAttributeConditional.new(id: 1, original_string: "{if @b}b{end}", attribute_name: "style")
    ]

    modified = AttributeMethodGenerator.inject_methods_into_class(ruby_code, "Test", conditionals)

    assert_includes modified, "def __mochi_attr_cond_0"
    assert_includes modified, "def __mochi_attr_cond_1"
  end

  def test_inject_methods_into_class_handles_text_before_conditional
    ruby_code = <<~RUBY
      class NavComponent
        def initialize
          @active = false
        end
      end
    RUBY

    conditionals = [
      ExtractedAttributeConditional.new(id: 0, original_string: "nav-item {if @active}active{end}", attribute_name: "class")
    ]

    modified = AttributeMethodGenerator.inject_methods_into_class(ruby_code, "NavComponent", conditionals)

    assert_includes modified, "nav-item "
  end
end
