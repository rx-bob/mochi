# typed: false
require_relative "../test_helper"
require_relative "../../src/quickjs/bindings"
require_relative "../../src/quickjs/error"
require_relative "../../src/quickjs/value"
require_relative "../../src/quickjs/runtime"

class QuickJSBindingsTest < Minitest::Test
  def test_runtime_initialization_and_finalization
    js = QuickJS::Runtime.new
    js.close
  end

  def test_evaluates_simple_expressions
    js = QuickJS::Runtime.new
    result = js.eval("1 + 1")
    assert_equal 2, result.to_i
    js.close
  end

  def test_handles_different_types
    js = QuickJS::Runtime.new

    assert_equal 10, js.eval("10").to_i
    assert_equal "hello", js.eval("'hello'").to_s
    assert_equal true, js.eval("true").to_bool
    assert js.eval("null").null?
    assert js.eval("undefined").undefined?

    js.close
  end

  def test_handles_errors
    js = QuickJS::Runtime.new

    assert_raises(QuickJS::ReferenceError) do
      js.eval("unknownVariable")
    end

    assert_raises(QuickJS::SyntaxError) do
      js.eval("syntax error !!!")
    end

    js.close
  end

  def test_memory_cleanup
    js = QuickJS::Runtime.new
    100.times do
      v = js.eval("'test'")
      v.close
    end
    js.close
  end

  def test_eval_from_file
    path = "/tmp/test_script.js"
    File.write(path, "2 * 4")
    js = QuickJS::Runtime.new
    assert_equal 8, js.eval_file(path).to_i
    js.close
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_global_property_access
    js = QuickJS::Runtime.new
    js["myVar"] = 42
    assert_equal 42, js["myVar"].to_i
    js.close
  end

  def test_function_calls_on_global_object
    js = QuickJS::Runtime.new
    js.eval("function add(a, b) { return a + b; }")
    assert_equal 30, js.call("add", 10, 20).to_i
    js.close
  end

  def test_async_promises
    js = QuickJS::Runtime.new
    js.eval("var p = Promise.resolve(42)")
    js.run_jobs
    js.close
  end

  def test_json_stringify
    js = QuickJS::Runtime.new
    obj = js.eval("({a: 1})")
    assert_equal '{"a":1}', obj.to_json
    js.close
  end

  def test_typed_arrays
    js = QuickJS::Runtime.new
    arr = js.eval("new Uint8Array([1, 2, 3])")
    assert arr.uint8_array?
    assert_equal 3, arr.size
    js.close
  end

  def test_object_property_access
    js = QuickJS::Runtime.new
    obj = js.eval("({a: 1})")
    assert_equal 1, obj["a"].to_i
    obj["b"] = 2
    assert_equal 2, obj["b"].to_i
    js.close
  end

  def test_array_operations
    js = QuickJS::Runtime.new
    arr = js.eval("[1, 2, 3]")
    assert_equal 3, arr.size

    doubled = arr.map { |v| v.to_i * 2 }
    assert_equal [2, 4, 6], doubled

    js.close
  end

  def test_function_calls_on_values
    js = QuickJS::Runtime.new
    func = js.eval("(function(a) { return a * a; })")
    assert_equal 25, func.call(5).to_i
    js.close
  end

  def test_complex_conversions
    js = QuickJS::Runtime.new

    arr = js.eval("[10, 20]")
    crystal_arr = arr.to_a
    assert_equal 2, crystal_arr.size
    assert_equal 10, crystal_arr[0].to_i

    obj = js.eval("({x: 1, y: 2})")
    h = obj.to_h
    assert_equal 1, h["x"].to_i
    assert_equal 2, h["y"].to_i

    js.close
  end
end
