# typed: false
require_relative "../test_helper"
require_relative "../../src/js/js_logger"

class JsLoggerGeneratorTest < Minitest::Test
  def test_generate_returns_string
    result = JsLoggerGenerator.generate
    assert_instance_of String, result
  end

  def test_generate_contains_il_class
    result = JsLoggerGenerator.generate
    assert_includes result, "class il"
  end

  def test_generate_contains_format_log_method
    result = JsLoggerGenerator.generate
    assert_includes result, "static formatLog(msg, suffix)"
  end

  def test_generate_contains_debug_method
    result = JsLoggerGenerator.generate
    assert_includes result, "static debug(msg)"
  end

  def test_generate_contains_info_method
    result = JsLoggerGenerator.generate
    assert_includes result, "static info(msg)"
  end

  def test_generate_contains_warn_method
    result = JsLoggerGenerator.generate
    assert_includes result, "static warn(msg)"
  end

  def test_generate_contains_error_method
    result = JsLoggerGenerator.generate
    assert_includes result, "static error(msg)"
  end

  def test_generate_contains_console_debug_call
    result = JsLoggerGenerator.generate
    assert_includes result, "console.debug"
  end

  def test_generate_contains_console_log_call
    result = JsLoggerGenerator.generate
    assert_includes result, "console.log"
  end

  def test_generate_contains_console_warn_call
    result = JsLoggerGenerator.generate
    assert_includes result, "console.warn"
  end

  def test_generate_contains_console_error_call
    result = JsLoggerGenerator.generate
    assert_includes result, "console.error"
  end

  def test_generate_wraps_calls_in_conditional
    result = JsLoggerGenerator.generate
    # int_logs_enabled is false, so all conditions are `false && ...`
    assert_includes result, "if (false && false)"
  end

  def test_generate_has_color_definitions
    result = JsLoggerGenerator.generate
    assert_includes result, "color: yellow"
    assert_includes result, "color: inherit"
  end
end
