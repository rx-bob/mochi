# typed: false
require_relative "../test_helper"
require_relative "../../src/html/each_processor"
require_relative "../../src/ruby/each_method_generator"
require_relative "../../src/ruby/conditional_method_generator"

class EachMethodGeneratorTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/ruby", __dir__)

  def test_generate_method_no_index
    exp_code = File.read(File.join(FIXTURES_DIR, "each_generated_method_a.rb"))
    loop_def = EachProcessor.extract_loop_definition("@items as item")
    refute_nil loop_def

    block = EachBlock.new(
      loop_def: T.must(loop_def),
      content: "<li>{item.name}</li>",
      start_pos: 0,
      end_pos: 56,
      content_start_pos: 31,
      id: 123
    )

    ruby_code = EachMethodGenerator.generate_method(block, "abc")
    assert_equal exp_code, ruby_code
  end

  def test_generate_method_with_index
    exp_code = File.read(File.join(FIXTURES_DIR, "each_method_array_entry_k.rb"))
    loop_def = EachProcessor.extract_loop_definition("@array as entry, k")
    refute_nil loop_def

    block = EachBlock.new(
      loop_def: T.must(loop_def),
      content: "<li>{entry.name}</li>",
      start_pos: 0,
      end_pos: 56,
      content_start_pos: 31,
      id: 123
    )

    ruby_code = EachMethodGenerator.generate_method(block, "abc")
    assert_equal exp_code, ruby_code
  end

  def test_inject_no_each_blocks
    each_blocks = T::Array[EachBlock].new
    result = EachMethodGenerator.inject_methods_into_class("", "", each_blocks)
    assert_equal "", result
  end

  def test_generate_method_creates_correct_method_names
    loop_def = EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil)
    block = EachBlock.new(
      loop_def: loop_def,
      content: "<p>{item.text}</p>",
      start_pos: 0,
      end_pos: 20,
      content_start_pos: 10,
      id: 42
    )

    ruby_code = EachMethodGenerator.generate_method(block, "Test")

    assert_includes ruby_code, "def __mochi_each_42_items"
    assert_includes ruby_code, "def __mochi_each_42_key"
  end

  def test_generate_method_returns_array_and_key
    loop_def = EachLoopDef.new(array_name: "@users", item_name: "user", index_name: "i")
    block = EachBlock.new(
      loop_def: loop_def,
      content: "<div>{user.name}</div>",
      start_pos: 0,
      end_pos: 30,
      content_start_pos: 15,
      id: 1
    )

    ruby_code = EachMethodGenerator.generate_method(block, "UserList")

    assert_includes ruby_code, "return @users"
    assert_includes ruby_code, "user"
    assert_includes ruby_code, ".id"
    assert_includes ruby_code, "typeof"
  end

  def test_generate_method_includes_auto_generated_comment
    loop_def = EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil)
    block = EachBlock.new(
      loop_def: loop_def,
      content: "<p>content</p>",
      start_pos: 0,
      end_pos: 20,
      content_start_pos: 10,
      id: 0
    )

    ruby_code = EachMethodGenerator.generate_method(block, "Test")

    assert_includes ruby_code, "# auto-generated each method"
  end

  def test_generate_method_handles_different_array_names
    loop_def = EachLoopDef.new(array_name: "@products", item_name: "prod", index_name: nil)
    block = EachBlock.new(
      loop_def: loop_def,
      content: "<li>{prod.title}</li>",
      start_pos: 0,
      end_pos: 25,
      content_start_pos: 12,
      id: 5
    )

    ruby_code = EachMethodGenerator.generate_method(block, "ProductList")

    assert_includes ruby_code, "return @products"
  end

  def test_generate_all_methods_generates_multiple_methods
    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil),
        content: "<p>{item.name}</p>",
        start_pos: 0,
        end_pos: 20,
        content_start_pos: 10,
        id: 0
      ),
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@users", item_name: "user", index_name: "i"),
        content: "<div>{user.email}</div>",
        start_pos: 30,
        end_pos: 60,
        content_start_pos: 40,
        id: 1
      ),
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@products", item_name: "prod", index_name: nil),
        content: "<li>{prod.title}</li>",
        start_pos: 70,
        end_pos: 100,
        content_start_pos: 80,
        id: 2
      )
    ]

    code = EachMethodGenerator.generate_all_methods(blocks, "TestComponent")

    assert_includes code, "def __mochi_each_0_items"
    assert_includes code, "def __mochi_each_0_key"
    assert_includes code, "def __mochi_each_1_items"
    assert_includes code, "def __mochi_each_1_key"
    assert_includes code, "def __mochi_each_2_items"
    assert_includes code, "def __mochi_each_2_key"
    assert_includes code, "return @items"
    assert_includes code, "return @users"
    assert_includes code, "return @products"
  end

  def test_generate_all_methods_returns_empty_string_for_empty_array
    code = EachMethodGenerator.generate_all_methods(T::Array[EachBlock].new, "Test")
    assert_equal "", code
  end

  def test_generate_all_methods_handles_single_each_block
    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@data", item_name: "d", index_name: nil),
        content: "<span>{d.value}</span>",
        start_pos: 0,
        end_pos: 25,
        content_start_pos: 12,
        id: 99
      )
    ]

    code = EachMethodGenerator.generate_all_methods(blocks, "Single")

    assert_includes code, "def __mochi_each_99_items"
    assert_includes code, "def __mochi_each_99_key"
    assert_includes code, "return @data"
  end

  def test_inject_methods_into_class_injects_before_class_end
    ruby_code = File.read(File.join(FIXTURES_DIR, "simple_component.rb"))

    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil),
        content: "<p>{item.name}</p>",
        start_pos: 0,
        end_pos: 20,
        content_start_pos: 10,
        id: 0
      )
    ]

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "SimpleComponent", blocks)

    assert_includes modified, "def __mochi_each_0_items"
    assert_includes modified, "def __mochi_each_0_key"
    assert_includes modified, "return @items"

    items_method_index = modified.index("def __mochi_each_0_items")
    final_end_index = modified.rindex("end")

    assert items_method_index
    assert final_end_index
    assert_operator items_method_index, :<, final_end_index
  end

  def test_inject_methods_into_class_handles_multiple_each_blocks
    ruby_code = File.read(File.join(FIXTURES_DIR, "simple_component.rb"))

    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil),
        content: "<p>{item.name}</p>",
        start_pos: 0,
        end_pos: 20,
        content_start_pos: 10,
        id: 0
      ),
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@users", item_name: "user", index_name: "idx"),
        content: "<div>{user.email}</div>",
        start_pos: 30,
        end_pos: 60,
        content_start_pos: 40,
        id: 1
      )
    ]

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "SimpleComponent", blocks)

    assert_includes modified, "def __mochi_each_0_items"
    assert_includes modified, "def __mochi_each_0_key"
    assert_includes modified, "def __mochi_each_1_items"
    assert_includes modified, "def __mochi_each_1_key"
  end

  def test_inject_methods_into_class_handles_complex_classes_with_nested_methods
    ruby_code = File.read(File.join(FIXTURES_DIR, "complex_component.rb"))

    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: "i"),
        content: "<li>{item.title} - {i}</li>",
        start_pos: 0,
        end_pos: 30,
        content_start_pos: 15,
        id: 0
      )
    ]

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "ComplexComponent", blocks)

    assert_includes modified, "def __mochi_each_0_items"
    assert_includes modified, "def __mochi_each_0_key"

    assert_includes modified, "def initialize"
    assert_includes modified, "def add_item"
    assert_includes modified, "def helper_method"
    assert_includes modified, "def render"
  end

  def test_inject_methods_into_class_preserves_existing_code_structure
    ruby_code = <<~RUBY
      class ItemList
        def initialize
          @items = []
        end

        def count
          @items.size
        end
      end
    RUBY

    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil),
        content: "<p>{item.text}</p>",
        start_pos: 0,
        end_pos: 20,
        content_start_pos: 10,
        id: 3
      )
    ]

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "ItemList", blocks)

    assert_includes modified, "def initialize"
    assert_includes modified, "def count"
    assert_includes modified, "@items = []"
    assert_includes modified, "@items.size"
    assert_includes modified, "def __mochi_each_3_items"
    assert_includes modified, "def __mochi_each_3_key"
  end

  def test_inject_methods_into_class_handles_empty_ruby_code_gracefully
    ruby_code = ""
    blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: nil),
        content: "<p>test</p>",
        start_pos: 0,
        end_pos: 10,
        content_start_pos: 5,
        id: 0
      )
    ]

    modified = EachMethodGenerator.inject_methods_into_class(ruby_code, "Test", blocks)
    assert_equal ruby_code, modified
  end

  def test_inject_methods_into_class_works_together_with_conditional_method_injection
    ruby_code = <<~RUBY
      class MixedComponent
        def initialize
          @items = []
          @show_list = false
        end

        def add_item(item)
          @items << item
        end
      end
    RUBY

    each_blocks = [
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@items", item_name: "item", index_name: "idx"),
        content: "<li>{item.name} - {idx}</li>",
        start_pos: 0,
        end_pos: 30,
        content_start_pos: 15,
        id: 0
      ),
      EachBlock.new(
        loop_def: EachLoopDef.new(array_name: "@users", item_name: "user", index_name: nil),
        content: "<div>{user.email}</div>",
        start_pos: 50,
        end_pos: 80,
        content_start_pos: 60,
        id: 1
      )
    ]

    conditional_blocks = [
      ConditionalBlock.new(condition: "@show_list", content: "", start_pos: 0, end_pos: 10, content_start_pos: 0, id: 0),
      ConditionalBlock.new(condition: "@items.length > 0", content: "", start_pos: 20, end_pos: 30, content_start_pos: 20, id: 1)
    ]

    modified = ConditionalMethodGenerator.inject_methods_into_class(ruby_code, "MixedComponent", conditional_blocks)
    modified = EachMethodGenerator.inject_methods_into_class(modified, "MixedComponent", each_blocks)

    assert_includes modified, "def __mochi_cond_0"
    assert_includes modified, "@show_list"
    assert_includes modified, "def __mochi_cond_1"
    assert_includes modified, "@items.length > 0"

    assert_includes modified, "def __mochi_each_0_items"
    assert_includes modified, "def __mochi_each_0_key(item, idx)"
    assert_includes modified, "return @items"
    assert_includes modified, "def __mochi_each_1_items"
    assert_includes modified, "def __mochi_each_1_key(user, index)"
    assert_includes modified, "return @users"

    assert_includes modified, "def initialize"
    assert_includes modified, "def add_item"

    final_end_index = modified.rindex("end")
    assert final_end_index

    cond_0_index = modified.index("def __mochi_cond_0")
    each_0_index = modified.index("def __mochi_each_0_items")

    assert cond_0_index
    assert each_0_index
    assert_operator cond_0_index, :<, final_end_index
    assert_operator each_0_index, :<, final_end_index
  end
end
