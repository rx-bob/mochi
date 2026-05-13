# typed: false
require_relative "../test_helper"
require_relative "../../src/html/conditional_processor"
require_relative "../../src/ruby/conditional_method_generator"

class ConditionalMethodGeneratorTest < Minitest::Test
  def test_generate_method_creates_conditional_method
    block = ConditionalBlock.new(
      condition: "@count > 5",
      content: "<p>High</p>",
      start_pos: 0,
      end_pos: 10,
      content_start_pos: 0,
      id: 0
    )

    method_code = ConditionalMethodGenerator.generate_method(block, "Counter")

    assert_includes method_code, "def __mochi_cond_0"
    assert_includes method_code, "@count > 5"
    assert_includes method_code, "end"
  end

  def test_generate_method_handles_complex_conditions
    block = ConditionalBlock.new(
      condition: "@items.length > 0 && @enabled",
      content: "<p>Content</p>",
      start_pos: 0,
      end_pos: 10,
      content_start_pos: 0,
      id: 3
    )

    method_code = ConditionalMethodGenerator.generate_method(block, "MyComponent")

    assert_includes method_code, "def __mochi_cond_3"
    assert_includes method_code, "@items.length > 0 && @enabled"
  end

  def test_generate_method_handles_ruby_method_calls
    block = ConditionalBlock.new(
      condition: "@items.empty?",
      content: "<p>No items</p>",
      start_pos: 0,
      end_pos: 10,
      content_start_pos: 0,
      id: 1
    )

    method_code = ConditionalMethodGenerator.generate_method(block, "List")

    assert_includes method_code, "def __mochi_cond_1"
    assert_includes method_code, "@items.empty?"
  end

  def test_generate_all_methods_generates_multiple_methods
    blocks = [
      ConditionalBlock.new(condition: "@a", content: "", start_pos: 0, end_pos: 10, content_start_pos: 0, id: 0),
      ConditionalBlock.new(condition: "@b", content: "", start_pos: 11, end_pos: 20, content_start_pos: 11, id: 1),
      ConditionalBlock.new(condition: "@c", content: "", start_pos: 21, end_pos: 30, content_start_pos: 21, id: 2)
    ]

    code = ConditionalMethodGenerator.generate_all_methods(blocks, "Test")

    assert_includes code, "def __mochi_cond_0"
    assert_includes code, "def __mochi_cond_1"
    assert_includes code, "def __mochi_cond_2"
    assert_includes code, "@a"
    assert_includes code, "@b"
    assert_includes code, "@c"
  end

  def test_generate_all_methods_returns_empty_string_for_empty_array
    code = ConditionalMethodGenerator.generate_all_methods([], "Test")
    assert_equal "", code
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

    blocks = [
      ConditionalBlock.new(condition: "@count > 5", content: "", start_pos: 0, end_pos: 10, content_start_pos: 0, id: 0)
    ]

    modified = ConditionalMethodGenerator.inject_methods_into_class(ruby_code, "Counter", blocks)

    assert_includes modified, "def __mochi_cond_0"
    assert_includes modified, "@count > 5"

    cond_method_index = modified.index("def __mochi_cond_0")
    final_end_index = modified.rindex("end")

    assert cond_method_index
    assert final_end_index
    assert_operator cond_method_index, :<, final_end_index
  end

  def test_inject_methods_into_class_handles_multiple_conditionals
    ruby_code = <<~RUBY
      class Test
        def foo
          "bar"
        end
      end
    RUBY

    blocks = [
      ConditionalBlock.new(condition: "@a", content: "", start_pos: 0, end_pos: 5, content_start_pos: 0, id: 0),
      ConditionalBlock.new(condition: "@b", content: "", start_pos: 6, end_pos: 10, content_start_pos: 6, id: 1),
      ConditionalBlock.new(condition: "@c", content: "", start_pos: 11, end_pos: 15, content_start_pos: 11, id: 2)
    ]

    modified = ConditionalMethodGenerator.inject_methods_into_class(ruby_code, "Test", blocks)

    assert_includes modified, "def __mochi_cond_0"
    assert_includes modified, "def __mochi_cond_1"
    assert_includes modified, "def __mochi_cond_2"
    assert_includes modified, "@a"
    assert_includes modified, "@b"
    assert_includes modified, "@c"
  end

  def test_inject_methods_into_class_returns_unchanged_when_no_conditionals
    ruby_code = "class Test\nend"
    blocks = []

    modified = ConditionalMethodGenerator.inject_methods_into_class(ruby_code, "Test", blocks)
    assert_equal ruby_code, modified
  end

  def test_inject_methods_into_class_handles_nested_methods
    ruby_code = <<~RUBY
      class Component
        def initialize
          @value = 0
        end

        def helper
          if @value > 0
            puts "positive"
          end
        end

        def render
          "html"
        end
      end
    RUBY

    blocks = [
      ConditionalBlock.new(condition: "@value > 10", content: "", start_pos: 0, end_pos: 10, content_start_pos: 0, id: 0)
    ]

    modified = ConditionalMethodGenerator.inject_methods_into_class(ruby_code, "Component", blocks)

    assert_includes modified, "def __mochi_cond_0"
    assert_includes modified, "@value > 10"
    assert_includes modified, "def initialize"
    assert_includes modified, "def helper"
    assert_includes modified, "def render"
  end

  def test_inject_methods_into_class_handles_find_second_last_end
    text = <<~TEXT
      class Test
        def method
          code
        end
      end
    TEXT

    blocks = [ConditionalBlock.new(condition: "@test", content: "", start_pos: 0, end_pos: 5, content_start_pos: 0, id: 0)]

    result = ConditionalMethodGenerator.inject_methods_into_class(text, "Test", blocks)

    assert_includes result, "def __mochi_cond_0"
  end
end
