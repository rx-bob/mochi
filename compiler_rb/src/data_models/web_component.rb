# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class WebComponent < T::Struct
  const :name, String
  const :js_code, String
end
