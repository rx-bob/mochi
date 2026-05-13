# typed: false
require_relative "../test_helper"
require_relative "../../src/ruby/inject_utils"

class InjectUtilsTest < Minitest::Test
  def test_find_second_last_end
    text = "class Foo\nend\nend"
    result = InjectUtils.find_second_last_end(text, "end")
    assert_equal 10, result
  end

  def test_find_second_last_end_not_found
    text = "class Foo"
    result = InjectUtils.find_second_last_end(text, "end")
    assert_nil result
  end

  def test_find_second_last_end_single_occurrence
    text = "class Foo\nend"
    result = InjectUtils.find_second_last_end(text, "end")
    assert_nil result
  end

  def test_find_second_last_end_with_word_boundary_end
    text = "end\nclass Foo\nend"
    result = InjectUtils.find_second_last_end(text, "end")
    assert_equal 0, result
  end

  def test_insert_code
    result = InjectUtils.insert_code("abcdef", 3, "XYZ")
    assert_equal "abcXYZdef", result
  end

  def test_insert_code_at_start
    result = InjectUtils.insert_code("abc", 0, "XYZ")
    assert_equal "XYZabc", result
  end

  def test_insert_code_at_end
    result = InjectUtils.insert_code("abc", 3, "XYZ")
    assert_equal "abcXYZ", result
  end

  def test_calculate_insertion_point_with_newline
    code = "class Foo\nend\nend"
    # "end" at position 10, newline after at position 13
    result = InjectUtils.calculate_insertion_point(code, 10, 3)
    assert_equal 14, result
  end

  def test_calculate_insertion_point_without_newline
    code = "class Foo end"
    result = InjectUtils.calculate_insertion_point(code, 10, 3)
    assert_equal 13, result
  end

  def test_find_insertion_point_success
    ruby_code = "class Counter\n  def initialize\n    @count = 0\n  end\n\n  def increment\n    @count += 1\n  end\nend"
    result = InjectUtils.find_insertion_point(ruby_code, "Counter", "end", 3)
    assert result
    # The second-to-last "end" is the one closing the increment method
    # After that should come a newline, then the class-closing end
    assert_operator T.unsafe(result), :<, ruby_code.length
  end

  def test_find_insertion_point_returns_nil_when_no_second_last_end
    ruby_code = "class Counter"
    result = InjectUtils.find_insertion_point(ruby_code, "Counter", "end", 3)
    assert_nil result
  end

  def test_find_insertion_point_injects_before_final_end
    ruby_code = "class Test\n  def foo\n    1\n  end\nend"
    result = InjectUtils.find_insertion_point(ruby_code, "Test", "end", 3)
    assert result
    insert_pos = T.unsafe(result)
    modified = InjectUtils.insert_code(ruby_code, insert_pos, "  def bar\n    2\n  end\n")
    assert_equal "class Test\n  def foo\n    1\n  end\n  def bar\n    2\n  end\nend", modified
  end
end
