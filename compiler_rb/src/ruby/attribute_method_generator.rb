# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../html/conditional_processor"
require_relative "inject_utils"

class AttributeMethodGenerator
  extend T::Sig

  METHOD_PREFIX = "__mochi_attr_cond_"
  END_KEYWORD   = "end"
  FALLBACK_OFFSET = 3

  sig do
    params(
      ruby_code: String,
      class_name: String,
      conditionals: T::Array[ExtractedAttributeConditional]
    ).returns(String)
  end
  def self.inject_methods_into_class(ruby_code, class_name, conditionals)
    return ruby_code if conditionals.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(conditionals)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  sig { params(conditionals: T::Array[ExtractedAttributeConditional]).returns(String) }
  def self.generate_all_methods(conditionals)
    conditionals.map { |cond| generate_method(cond) }.join("\n")
  end

  sig { params(cond: ExtractedAttributeConditional).returns(String) }
  def self.generate_method(cond)
    method_name = "#{METHOD_PREFIX}#{cond.id}"
    attr_string = cond.original_string

    blocks = ConditionalProcessor.extract_conditionals(attr_string)
    blocks.sort_by! { |b| b.start_pos }

    body_lines = []
    body_lines << '    _res = ""'

    last_pos = 0
    blocks.each do |block|
      if block.start_pos > last_pos
        text = T.must(attr_string[last_pos...block.start_pos])
        body_lines << "    _res += \"#{escape_and_interpolate(text)}\""
      end

      body_lines << "    if #{block.condition}"
      body_lines << "      _res += \"#{escape_and_interpolate(block.content)}\""
      body_lines << "    end"

      last_pos = block.end_pos
    end

    if last_pos < attr_string.size
      text = T.must(attr_string[last_pos..])
      body_lines << "    _res += \"#{escape_and_interpolate(text)}\""
    end

    body_lines << "    _res"

    lines = []
    lines << ""
    lines << "  # auto-generated attribute conditional method"
    lines << "  def #{method_name}"
    lines.concat(body_lines)
    lines << "  end"
    lines << ""

    lines.join("\n")
  end

  sig { params(text: String).returns(String) }
  def self.escape_and_interpolate(text)
    escaped = text.gsub("\"", "\\\"")
    escaped.gsub(/\{([^}]+)\}/) do |_match|
      inner = T.must(T.must(Regexp.last_match)[1]).strip
      "\#{#{inner}}"
    end
  end
end
