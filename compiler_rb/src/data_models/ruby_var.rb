# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class RubyVariable < T::Struct
  const :value, String
  const :exported, T::Boolean
end
