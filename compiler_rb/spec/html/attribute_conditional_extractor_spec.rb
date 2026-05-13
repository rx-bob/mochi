# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/html/attribute_conditional_extractor"

class AttributeConditionalExtractorTest < Minitest::Test
  def test_extracts_single_conditional_attribute
    html = %Q{<a class="nav-item {if @active}active{end}">Link</a>}
    result = AttributeConditionalExtractor.process(html)

    assert_equal 1, result.conditionals.size
    cond = result.conditionals[0]
    assert_equal 0, cond.id
    assert_equal "class", cond.attribute_name
    assert_equal "nav-item {if @active}active{end}", cond.original_string

    assert_equal %Q{<a class="{__mochi_attr_cond_0}">Link</a>}, result.html
  end

  def test_extracts_multiple_conditional_attributes
    html = %Q{<div class="{if @a}a{end}" data-val='{unless @b}b{end}'></div>}
    result = AttributeConditionalExtractor.process(html)

    assert_equal 2, result.conditionals.size

    cond0 = result.conditionals[0]
    assert_equal "class", cond0.attribute_name
    assert_equal "{if @a}a{end}", cond0.original_string

    cond1 = result.conditionals[1]
    assert_equal "data-val", cond1.attribute_name
    assert_equal "{unless @b}b{end}", cond1.original_string

    assert_equal %Q{<div class="{__mochi_attr_cond_0}" data-val='{__mochi_attr_cond_1}'></div>}, result.html
  end

  def test_leaves_attributes_without_conditionals_alone
    html = %Q{<a class="nav-item" href="{url}">Link</a>}
    result = AttributeConditionalExtractor.process(html)

    assert_equal 0, result.conditionals.size
    assert_equal html, result.html
  end

  def test_leaves_block_conditionals_alone
    html = %Q{<div>{if @active}<span>Active</span>{end}</div>}
    result = AttributeConditionalExtractor.process(html)

    assert_equal 0, result.conditionals.size
    assert_equal html, result.html
  end

  def test_handles_conditionals_with_multiple_branches
    html = %Q{<a class="nav {if @x}x{elsif @y}y{else}z{end}">Link</a>}
    result = AttributeConditionalExtractor.process(html)

    assert_equal 1, result.conditionals.size
    assert_equal %Q{<a class="{__mochi_attr_cond_0}">Link</a>}, result.html
    assert_equal "nav {if @x}x{elsif @y}y{else}z{end}", result.conditionals[0].original_string
  end
end
