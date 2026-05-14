# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "runtime"

module QuickJS
  module Opal
    class Compiler
      extend T::Sig

      sig { void }
      def initialize
        @js = T.let(Runtime.new, Runtime)
        # at least 64MB
        @js.set_max_stack_size(64 * 1024 * 1024)
        load_opal
      end

      sig { void }
      def finalize
        @js.close
      end

      sig { params(ruby_code: String, filename: T.nilable(String), requirable: T::Boolean).returns(String) }
      def compile(ruby_code, filename = nil, requirable = false)
        @js["__temp_ruby_code__"] = ruby_code

        opts = String.new
        opts << "{"
        opts << "file: '#{filename}'," if filename
        opts << "requirable: true," if requirable
        opts << "method_missing: false,"
        opts << "arity_check: false,"
        opts << "frozen_string_literal: true,"
        opts << "}"

        result = @js.eval("Opal.compile(__temp_ruby_code__, #{opts})")
        result.to_s
      end

      sig { params(ruby_code: String).returns(QuickJS::Value) }
      def eval(ruby_code)
        js_code = compile(ruby_code)
        @js.eval(js_code)
      end

      private

      sig { void }
      def load_opal
        exe_dir = File.dirname($PROGRAM_NAME)
        candidates = [
          File.expand_path("../../../fragments/vendor/opal", __dir__),
          File.expand_path("../../fragments/vendor/opal", __dir__),
          File.join(exe_dir, "../fragments/vendor/opal"),
          File.join(exe_dir, "fragments/vendor/opal"),
        ]
        base_path = candidates.find { |p| File.exist?(File.join(p, "opal.js")) }

        raise "Opal vendor files not found at #{candidates.join(" or ")}" unless base_path

        opal_path = File.join(base_path, "opal.js")
        parser_path = File.join(base_path, "opal-parser.js")

        unless File.exist?(opal_path) && File.exist?(parser_path)
          raise "Opal vendor files not found at #{opal_path} or #{parser_path}"
        end

        @js.eval_file(opal_path)

        unless @js["Opal"].object?
          raise "Opal failed to load"
        end

        @js.eval_file(parser_path)
        @js.eval("Opal.load('opal-parser')")

        # Opal is loaded?
        unless @js["Opal"].object?
          raise "Opal failed to load"
        end
      end
    end
  end
end
