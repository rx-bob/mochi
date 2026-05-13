# typed: false
require_relative "../test_helper"
require_relative "../../src/data_models/ruby_endable_statement"

class RubyEndableStatementTest < Minitest::Test
  def test_get_endable_class
    result = RubyEndableStatement.get_endable("class Foo")
    assert_equal RubyEndableStatement::CLASS, result
  end

  def test_get_endable_module
    result = RubyEndableStatement.get_endable("module Bar")
    assert_equal RubyEndableStatement::MODULE, result
  end

  def test_get_endable_def
    result = RubyEndableStatement.get_endable("def foo")
    assert_equal RubyEndableStatement::DEF, result
  end

  def test_get_endable_if
    result = RubyEndableStatement.get_endable("if true")
    assert_equal RubyEndableStatement::IF, result
  end

  def test_get_endable_unless
    result = RubyEndableStatement.get_endable("unless false")
    assert_equal RubyEndableStatement::UNLESS, result
  end

  def test_get_endable_case
    result = RubyEndableStatement.get_endable("case x")
    assert_equal RubyEndableStatement::CASE, result
  end

  def test_get_endable_while
    result = RubyEndableStatement.get_endable("while true")
    assert_equal RubyEndableStatement::WHILE, result
  end

  def test_get_endable_until
    result = RubyEndableStatement.get_endable("until false")
    assert_equal RubyEndableStatement::UNTIL, result
  end

  def test_get_endable_for
    result = RubyEndableStatement.get_endable("for i in items")
    assert_equal RubyEndableStatement::FOR, result
  end

  def test_get_endable_begin
    result = RubyEndableStatement.get_endable("begin")
    assert_equal RubyEndableStatement::BEGIN_BLOCK, result
  end

  def test_get_endable_no_match
    result = RubyEndableStatement.get_endable("xyz")
    assert_nil result
  end

  def test_get_endable_partial_match_inside_word_matches_prefix
    result = RubyEndableStatement.get_endable("ifdef something")
    assert_equal RubyEndableStatement::IF, result
  end

  def test_serialize_values
    assert_equal "class", RubyEndableStatement::CLASS.serialize
    assert_equal "module", RubyEndableStatement::MODULE.serialize
    assert_equal "def", RubyEndableStatement::DEF.serialize
    assert_equal "if", RubyEndableStatement::IF.serialize
    assert_equal "unless", RubyEndableStatement::UNLESS.serialize
    assert_equal "case", RubyEndableStatement::CASE.serialize
    assert_equal "while", RubyEndableStatement::WHILE.serialize
    assert_equal "until", RubyEndableStatement::UNTIL.serialize
    assert_equal "for", RubyEndableStatement::FOR.serialize
    assert_equal "begin", RubyEndableStatement::BEGIN_BLOCK.serialize
  end
end
