# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class RubyDef < T::Struct
  const :name, T.nilable(String)
  const :file_name, String
  const :class_name, String
  const :body, T::Array[String]
  const :parameters, T::Array[String]
end
