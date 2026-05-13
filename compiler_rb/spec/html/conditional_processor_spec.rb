# typed: false
require_relative "../test_helper"
require_relative "../../src/html/conditional_processor"

class ConditionalProcessorTest < Minitest::Test
  def test_processes_simple_if_condition
    html = %Q{
      <div>
        {if @show}
          <p>Visible!</p>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_includes result.html, "<!--if-anchor-0-->"
    assert_equal 1, result.conditionals.size
    assert_equal "@show", result.conditionals[0].condition
    assert_equal 0, result.conditionals[0].id
  end

  def test_processes_multiple_if_conditions
    html = %Q{
      <div>
        {if @show}
          <p>First</p>
        {end}
        {if @display}
          <p>Second</p>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_includes result.html, "<!--if-anchor-0-->"
    assert_includes result.html, "<!--if-anchor-1-->"
    ids = result.conditionals.map(&:id).sort
    assert_equal [0, 1], ids
  end

  def test_processes_nested_if_conditions
    html = %Q{
      <div>
        {if @show}
          <div>
            {if @nested}
              <p>Nested content</p>
            {end}
          </div>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_equal 2, result.conditionals.size
    assert_includes result.html, "<!--if-anchor-0-->"
    refute_includes result.html, "<!--if-anchor-1-->"

    ids = result.conditionals.map(&:id).sort
    assert_equal [0, 1], ids
  end

  def test_processes_condition_with_comparison_operators
    html = %Q{
      <div>
        {if @count > 5}
          <p>Greater than 5</p>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_equal 1, result.conditionals.size
    assert_equal "@count > 5", result.conditionals[0].condition
    assert_equal 0, result.conditionals[0].id
    assert_includes result.html, "<!--if-anchor-0-->"
  end

  def test_processes_condition_with_method_calls
    html = %Q{
      <div>
        {if @items.empty?}
          <p>No items</p>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_equal 1, result.conditionals.size
    assert_equal "@items.empty?", result.conditionals[0].condition
  end

  def test_handles_html_without_conditionals
    html = %Q{
      <div>
        <p>No conditionals here</p>
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_equal 0, result.conditionals.size
    assert_equal html, result.html
  end

  def test_preserves_whitespace_and_formatting
    html = %Q{
      <div class="wrapper">
        {if @show}
          <h1>Title</h1>
          <p>Paragraph</p>
        {end}
      </div>
    }

    result = ConditionalProcessor.process(html)

    assert_includes result.html, "<!--if-anchor-0-->"
  end

  def test_extract_conditionals_single_block
    html = "{if @show}<p>Content</p>{end}"
    blocks = ConditionalProcessor.extract_conditionals(html)

    assert_equal 1, blocks.size
    assert_equal "@show", blocks[0].condition
    assert_equal "<p>Content</p>", blocks[0].content
  end

  def test_extract_conditionals_nested_blocks
    html = "{if @outer}{if @inner}<p>Nested</p>{end}{end}"
    blocks = ConditionalProcessor.extract_conditionals(html)

    assert_equal 2, blocks.size
  end

  def test_extract_conditionals_multiple_separate_blocks
    html = "{if @a}<p>A</p>{end}{if @b}<p>B</p>{end}"
    blocks = ConditionalProcessor.extract_conditionals(html)

    assert_equal 2, blocks.size
  end

  def test_try_match_if_token_one_element
    html = "{if @abc}<span>Thomas</span>{end}"
    result = ConditionalProcessor.try_match_if_token(html, 0)
    assert result
    assert_equal "@abc", result.condition
    assert_equal 9, result.content_start

    result2 = ConditionalProcessor.try_match_if_token(html, 1)
    assert_nil result2
  end

  def test_block_contains
    outer = ConditionalBlock.new(
      condition: "@outer",
      content: "content",
      start_pos: 0,
      end_pos: 50,
      content_start_pos: 10,
      id: 0
    )
    inner = ConditionalBlock.new(
      condition: "@inner",
      content: "nested",
      start_pos: 15,
      end_pos: 40,
      content_start_pos: 25,
      id: 1
    )
    disjoint = ConditionalBlock.new(
      condition: "@other",
      content: "other",
      start_pos: 100,
      end_pos: 120,
      content_start_pos: 110,
      id: 2
    )

    assert outer.contains?(inner)
    refute inner.contains?(outer)
    refute outer.contains?(disjoint)
  end
end
