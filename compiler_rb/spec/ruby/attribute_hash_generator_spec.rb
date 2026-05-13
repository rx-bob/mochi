# typed: false
require_relative "../test_helper"
require_relative "../../src/html/attribute_hash_extractor"
require_relative "../../src/ruby/attribute_hash_generator"

class AttributeHashGeneratorTest < Minitest::Test
  def test_generates_a_method_that_serialized_the_truthy_keys
    html = %Q(<div class={{ "nav-item" => true, "active" => @is_active }}>)
    extractor_result = AttributeHashExtractor.process(html)

    ruby_code = <<~RUBY
      class MyComp
        def init
        end
      end
    RUBY

    amped_ruby = AttributeHashGenerator.inject_methods_into_class(ruby_code, "MyComp", extractor_result.hashes)

    assert_includes amped_ruby, "def __mochi_attr_hash_0"
    assert_includes amped_ruby, %Q(_hash = { "nav-item" => true, "active" => @is_active })
    assert_includes amped_ruby, %Q(_hash.select { |k, v| v }.keys.join(" "))
  end

  def test_generate_method_creates_attribute_hash_method
    hash = ExtractedAttributeHash.new(
      id: 0,
      original_string: '{{ "danger" => @active, "hidden" => !@visible }}',
      attribute_name: "class"
    )

    method_code = AttributeHashGenerator.generate_method(hash)

    assert_includes method_code, "def __mochi_attr_hash_0"
    assert_includes method_code, %Q(_hash = { "danger" => @active, "hidden" => !@visible })
    assert_includes method_code, %Q(_hash.select { |k, v| v }.keys.join(" "))
    assert_includes method_code, "end"
  end

  def test_generate_all_methods_generates_multiple_methods
    hashes = [
      ExtractedAttributeHash.new(id: 0, original_string: '{{ "a" => true }}', attribute_name: "class"),
      ExtractedAttributeHash.new(id: 1, original_string: '{{ "b" => @x }}', attribute_name: "style")
    ]

    code = AttributeHashGenerator.generate_all_methods(hashes)

    assert_includes code, "def __mochi_attr_hash_0"
    assert_includes code, "def __mochi_attr_hash_1"
  end

  def test_generate_all_methods_returns_empty_string_for_empty_array
    code = AttributeHashGenerator.generate_all_methods([])
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

    hashes = [
      ExtractedAttributeHash.new(id: 0, original_string: '{{ "active" => @active }}', attribute_name: "class")
    ]

    modified = AttributeHashGenerator.inject_methods_into_class(ruby_code, "Counter", hashes)

    assert_includes modified, "def __mochi_attr_hash_0"
    assert_includes modified, %Q(_hash = { "active" => @active })

    attr_method_index = modified.index("def __mochi_attr_hash_0")
    final_end_index = modified.rindex("end")

    assert attr_method_index
    assert final_end_index
    assert_operator attr_method_index, :<, final_end_index
  end

  def test_inject_methods_into_class_returns_unchanged_when_no_hashes
    ruby_code = "class Test\nend"
    hashes = []

    modified = AttributeHashGenerator.inject_methods_into_class(ruby_code, "Test", hashes)
    assert_equal ruby_code, modified
  end

  def test_inject_methods_into_class_with_quoted_original_string
    ruby_code = <<~RUBY
      class Test
        def foo
          "bar"
        end
      end
    RUBY

    hashes = [
      ExtractedAttributeHash.new(id: 0, original_string: '{{ "nav-item" => true, "active" => @is_active }}', attribute_name: "class")
    ]

    modified = AttributeHashGenerator.inject_methods_into_class(ruby_code, "Test", hashes)

    assert_includes modified, "def __mochi_attr_hash_0"
    assert_includes modified, %Q(_hash = { "nav-item" => true, "active" => @is_active })
  end
end
