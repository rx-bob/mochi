# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

module QuickJS
  class Error < StandardError
    extend T::Sig

    sig { params(message: String, js_stack: T.nilable(String)).void }
    def initialize(message, js_stack = nil)
      super(message)
      @js_stack = js_stack
    end

    sig { returns(T.nilable(String)) }
    attr_reader :js_stack
  end

  class EvalError      < Error; end
  class TypeError      < Error; end
  class ReferenceError < Error; end
  class SyntaxError    < Error; end
  class RangeError     < Error; end
  class InternalError  < Error; end
end
