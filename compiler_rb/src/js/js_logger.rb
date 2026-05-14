# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class JsLoggerGenerator
  extend T::Sig

  sig { void }
  def initialize
  end

  sig { returns(String) }
  def self.generate
    int_logs_enabled = false # TODO move to build config
    int_logs_level = "INFO" # TODO move to build config

    puts "> Internal Logs enabled: #{int_logs_enabled}"

    is_debug_or_above = T.let(int_logs_level == "DEBUG", T::Boolean)
    is_info_or_above = T.let(is_debug_or_above || int_logs_level == "INFO", T::Boolean)
    is_warn_or_above = T.let(is_info_or_above || int_logs_level == "WARN", T::Boolean)
    is_error_or_above = T.let(is_warn_or_above || int_logs_level == "ERROR", T::Boolean)

    color_a = "color: yellow; padding: 2px 6px; border-radius: 3px;"
    color_b = "color: inherit; background-color: inherit;"

    js_code = <<~JS

      class il {
          static formatLog(msg, suffix) {
              return "%c" + msg + " %c internal_log:" + suffix
          }

          static debug(msg) {
              if (#{int_logs_enabled} && #{is_debug_or_above}) {
                  console.debug(il.formatLog(msg, "debug"), "#{color_b}", "#{color_a}");
              }
          }

          static info(msg) {
              if (#{int_logs_enabled} && #{is_info_or_above}) {
                  console.log(il.formatLog(msg, "info"), "#{color_b}", "#{color_a}");
              }
          }

          static warn(msg) {
              if (#{int_logs_enabled} && #{is_warn_or_above}) {
                  console.warn(il.formatLog(msg, "warn"), "#{color_b}", "#{color_a}");
              }
          }

          static error(msg) {
              if (#{int_logs_enabled} && #{is_error_or_above}) {
                  console.error(il.formatLog(msg, "error"), "#{color_b}", "#{color_a}");
              }
          }
      }
    JS

    js_code
  end
end
