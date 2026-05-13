# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/html/attribute_hash_extractor"

class AttributeHashExtractorTest < Minitest::Test
  def test_extracts_hash_attributes_without_quotes
    html = %Q(<div class={{ "nav-item" => true, "active" => @is_active }}>)
    result = AttributeHashExtractor.process(html)

    assert_equal %Q(<div class="{__mochi_attr_hash_0}">), result.html
    assert_equal 1, result.hashes.size

    hash = result.hashes.first
    assert_equal 0, hash.id
    assert_equal "class", hash.attribute_name
    assert_equal %Q({{ "nav-item" => true, "active" => @is_active }}), hash.original_string
  end

  def test_extracts_hash_attributes_with_double_quotes
    html = %Q(<div class="{{ 'nav-item' => true, 'active' => @is_active }}">)
    result = AttributeHashExtractor.process(html)

    assert_equal %Q(<div class="{__mochi_attr_hash_0}">), result.html
    assert_equal 1, result.hashes.size

    hash = result.hashes.first
    assert_equal 0, hash.id
    assert_equal "class", hash.attribute_name
    assert_equal %Q({{ 'nav-item' => true, 'active' => @is_active }}), hash.original_string
  end

  def test_leaves_regular_attributes_untouched
    html = %Q(<div class="hello" title={@title}>)
    result = AttributeHashExtractor.process(html)

    assert_equal html, result.html
    assert_empty result.hashes
  end
end
