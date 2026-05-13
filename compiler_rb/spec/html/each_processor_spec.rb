# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/html/each_processor"

class EachProcessorTest < Minitest::Test
  def assert_loop_def(loop_def, array_name, item_name, index_name)
    assert_equal array_name, loop_def.array_name
    assert_equal item_name, loop_def.item_name
    assert_equal index_name, loop_def.index_name
  end

  def test_try_match_each_token_one_element
    html = "{each @items as item}<li>{item.name}</li>{end}"
    result = EachProcessor.try_match_each_token(html, 0)
    refute_nil result

    assert_loop_def(result.loop_def, "@items", "item", nil)
    assert_equal 21, result.content_start
  end

  def test_extract_loop_definition_no_index
    result = EachProcessor.extract_loop_definition("@items as item")
    refute_nil result
    assert_loop_def(result, "@items", "item", nil)
  end

  def test_extract_loop_definition_with_index_and_space
    result = EachProcessor.extract_loop_definition("@items as item, index")
    refute_nil result
    assert_loop_def(result, "@items", "item", "index")
  end

  def test_extract_loop_definition_with_index_no_space
    result = EachProcessor.extract_loop_definition("@items as item,index")
    refute_nil result
    assert_loop_def(result, "@items", "item", "index")
  end

  def test_extract_each_blocks
    html = "{each @items as item, index_nr}<li>{item.name}</li>{end}"
    result = EachProcessor.extract_each_blocks(html)
    refute_nil result
    assert_equal 1, result.size

    first = result[0]
    assert_loop_def(first.loop_def, "@items", "item", "index_nr")
    assert_equal "<li>{item.name}</li>", first.content
    assert_equal 0, first.start_pos
    assert_equal 56, first.end_pos
    assert_equal 31, first.content_start_pos
    assert_equal 0, first.id
  end

  def test_extract_each_blocks_nested
    html = "{each @items as item, index_nr}<li>{each @array as entry, k}<div>{entry}</div>{end}</li>{end}"
    result = EachProcessor.extract_each_blocks(html)
    refute_nil result
    assert_equal 2, result.size

    first = result[0]
    assert_loop_def(first.loop_def, "@array", "entry", "k")
    assert_equal "<div>{entry}</div>", first.content
    assert_equal 35, first.start_pos
    assert_equal 83, first.end_pos
    assert_equal 60, first.content_start_pos
    assert_equal 1, first.id

    second = result[1]
    assert_loop_def(second.loop_def, "@items", "item", "index_nr")
    assert_equal "<li>{each @array as entry, k}<div>{entry}</div>{end}</li>", second.content
    assert_equal 0, second.start_pos
    assert_equal 93, second.end_pos
    assert_equal 31, second.content_start_pos
    assert_equal 0, second.id
  end

  def test_replace_range
    result = EachProcessor.replace_range(">>>abc<<<", 3, 6, "def")
    assert_equal ">>>def<<<", result

    result2 = EachProcessor.replace_range(">>>abc<<<", 6, 3, "123")
    assert_equal ">>>abc123abc<<<", result2
  end

  def test_process_each_loops
    big_html = %Q{
      <div class="container">
        {each @items as item, index_nr}
          <li>
            {each @array as entry, k}
              <div>{entry}</div>
            {end}
          </li>
        {end}
        <h2>Section 2: Automation</h2>
        {each @items2 as it, j}
          <span>{it}</span>
        {end}
      </div>
    }

    expected_html_after = "\n      <div class=\"container\"\u003e\n        <!--each-anchor-0-->\n        <h2>Section 2: Automation</h2>\n        <!--each-anchor-2-->\n      </div>\n    "
    result = EachProcessor.process(big_html)
    assert_equal expected_html_after, result.html
    assert_equal 3, result.each_blocks.size

    inner = result.each_blocks[0]
    assert_loop_def(inner.loop_def, "@array", "entry", "k")
    assert_equal "\n              <div>{entry}</div>\n            ", inner.content
    assert_equal 98, inner.start_pos
    assert_equal 174, inner.end_pos
    assert_equal 123, inner.content_start_pos
    assert_equal 1, inner.id

    outer = result.each_blocks[1]
    assert_loop_def(outer.loop_def, "@items", "item", "index_nr")
    assert_includes outer.content, "{each @array as entry, k}"
    assert_equal 39, outer.start_pos
    assert_equal 204, outer.end_pos
    assert_equal 70, outer.content_start_pos
    assert_equal 0, outer.id

    second_top = result.each_blocks[2]
    assert_loop_def(second_top.loop_def, "@items2", "it", "j")
    assert_equal "\n          <span>{it}</span>\n        ", second_top.content
    assert_equal 252, second_top.start_pos
    assert_equal 317, second_top.end_pos
    assert_equal 275, second_top.content_start_pos
    assert_equal 2, second_top.id
  end
end
