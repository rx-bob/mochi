# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class RubyEndableStatement < T::Enum
  enums do
    CLASS = new("class")
    MODULE = new("module")
    DEF = new("def")
    IF = new("if")
    UNLESS = new("unless")
    CASE = new("case")
    WHILE = new("while")
    UNTIL = new("until")
    FOR = new("for")
    BEGIN_BLOCK = new("begin")
  end

  sig { params(input: String).returns(T.nilable(RubyEndableStatement)) }
  def self.get_endable(input)
    values.each do |statement_type|
      current_id = statement_type.serialize
      if input.start_with?(current_id)
        return statement_type
      end
    end
    nil
  end
end
