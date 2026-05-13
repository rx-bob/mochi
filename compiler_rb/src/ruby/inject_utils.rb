# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class InjectUtils
  extend T::Sig

  sig do
    params(
      ruby_code: String,
      class_name: String,
      end_keyword: String,
      fallback_offset: Integer
    ).returns(T.nilable(Integer))
  end
  def self.find_insertion_point(ruby_code, class_name, end_keyword, fallback_offset)
    second_last_end = find_second_last_end(ruby_code, end_keyword)

    unless second_last_end
      warn "Warning: Could not find insertion point for methods in class #{class_name}"
      return nil
    end

    calculate_insertion_point(ruby_code, second_last_end, fallback_offset)
  end

  sig { params(text: String, end_keyword: String).returns(T.nilable(Integer)) }
  def self.find_second_last_end(text, end_keyword)
    last_end = text.rindex(end_keyword)
    return nil unless last_end && last_end > 0

    text.rindex(end_keyword, last_end - 1)
  end

  sig do
    params(
      code: String,
      end_position: Integer,
      fallback_offset: Integer
    ).returns(Integer)
  end
  def self.calculate_insertion_point(code, end_position, fallback_offset)
    newline_after = code.index("\n", end_position)
    newline_after ? newline_after + 1 : end_position + fallback_offset
  end

  sig do
    params(
      original: String,
      position: Integer,
      code_to_insert: String
    ).returns(String)
  end
  def self.insert_code(original, position, code_to_insert)
    T.must(original[0...position]) + code_to_insert + T.must(original[position..])
  end
end
