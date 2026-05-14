# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

class ComponentGenerator
  extend T::Sig

  class Binding < T::Struct
    const :path, T::Array[Integer]
    const :type, Symbol # :text, :html, :attr, :anchor
    const :value, String
    const :name, T.nilable(String) # attribute name for :attr type

    def self.new(path:, type:, value:, name: nil)
      super
    end
  end
end
