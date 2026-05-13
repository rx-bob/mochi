# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../html/conditional_processor"
require_relative "inject_utils"

class ConditionalMethodGenerator
  extend T::Sig

  METHOD_PREFIX = "__mochi_cond_"
  END_KEYWORD   = "end"
  FALLBACK_OFFSET = 3

  sig do
    params(
      ruby_code: String,
      class_name: String,
      conditionals: T::Array[ConditionalBlock]
    ).returns(String)
  end
  def self.inject_methods_into_class(ruby_code, class_name, conditionals)
    return ruby_code if conditionals.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(conditionals, class_name)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  sig do
    params(
      conditionals: T::Array[ConditionalBlock],
      class_name: String
    ).returns(String)
  end
  def self.generate_all_methods(conditionals, class_name)
    conditionals.map { |block| generate_method(block, class_name) }.join("\n")
  end

  sig do
    params(
      block: ConditionalBlock,
      class_name: String
    ).returns(String)
  end
  def self.generate_method(block, class_name)
    method_name = "#{METHOD_PREFIX}#{block.id}"
    condition   = block.condition.strip

    <<~RUBY

        # auto-generated conditional method
        def #{method_name}
          #{condition}
        end
    RUBY
  end
end
