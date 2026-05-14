# typed: false
require_relative "../test_helper"
require_relative "../../src/quickjs/opal"

class QuickJSOpalCompilerTest < Minitest::Test
  def test_compiles_ruby_code_to_javascript
    compiler = QuickJS::Opal::Compiler.new
    js_code = compiler.compile("1 + 2")
    assert_includes js_code, "$rb_plus"
    compiler.finalize
  end

  def test_evaluates_ruby_code
    compiler = QuickJS::Opal::Compiler.new
    result = compiler.eval("1 + 2")
    assert_equal 3, result.to_i
    compiler.finalize
  end

  def test_handles_ruby_strings
    compiler = QuickJS::Opal::Compiler.new
    result = compiler.eval("'hello'.upcase")
    assert_equal "HELLO", result.to_s
    compiler.finalize
  end

  def test_can_define_and_call_ruby_methods
    compiler = QuickJS::Opal::Compiler.new
    compiler.eval("def greet(name); 'Hello ' + name; end")
    result = compiler.eval("greet('Crystal')")
    assert_equal "Hello Crystal", result.to_s
    compiler.finalize
  end
end
