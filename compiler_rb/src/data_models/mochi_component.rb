# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "web_component"

class MochiComponent < T::Struct
  const :absolute_path, String
  const :name, String
  const :imports, T::Array[String]
  const :ruby_code, String
  const :web_component, WebComponent
  const :html, String
  const :css, String
end
