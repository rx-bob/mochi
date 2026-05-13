# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../html/each_processor"
require_relative "inject_utils"

class EachMethodGenerator
  extend T::Sig

  METHOD_PREFIX = "__mochi_each_"
  END_KEYWORD   = "end"
  FALLBACK_OFFSET = 3

  sig do
    params(
      ruby_code: String,
      class_name: String,
      each_blocks: T::Array[EachBlock]
    ).returns(String)
  end
  def self.inject_methods_into_class(ruby_code, class_name, each_blocks)
    return ruby_code if each_blocks.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(each_blocks, class_name)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  sig do
    params(
      each_blocks: T::Array[EachBlock],
      class_name: String
    ).returns(String)
  end
  def self.generate_all_methods(each_blocks, class_name)
    each_blocks.map { |block| generate_method(block, class_name) }.join("\n")
  end

  sig do
    params(
      block: EachBlock,
      class_name: String
    ).returns(String)
  end
  def self.generate_method(block, class_name)
    method_name_items = "#{METHOD_PREFIX}#{block.id}_items"
    method_name_key = "#{METHOD_PREFIX}#{block.id}_key"
    array_name = block.loop_def.array_name
    item_name = block.loop_def.item_name
    index_name = block.loop_def.index_name || "index"

    lines = []
    lines << "  # auto-generated each method"
    lines << "  def #{method_name_items}"
    lines << "    return #{array_name}"
    lines << "  end"
    lines << ""
    lines << "  def #{method_name_key}(#{item_name}, #{index_name})"
    lines << "    # Use pure JavaScript to safely access id from both Ruby and JS objects"
    lines << "    `"
    lines << "      if (typeof \#{#{item_name}} === 'object' && \#{#{item_name}} !== null) {"
    lines << "        // Check for plain JS object with id property"
    lines << "        if (\#{#{item_name}}.id !== undefined && typeof \#{#{item_name}}.$id !== 'function') {"
    lines << "          return \#{#{item_name}}.id;"
    lines << "        }"
    lines << "        // Check for Ruby object with $id method"
    lines << "        if (typeof \#{#{item_name}}.$id === 'function') {"
    lines << "          try {"
    lines << "            return \#{#{item_name}}.$id();"
    lines << "          } catch(e) {"
    lines << "            // Fall through to index"
    lines << "          }"
    lines << "        }"
    lines << "      }"
    lines << "      return \#{#{index_name}};"
    lines << "    `"
    lines << "  end"
    lines << ""

    lines.join("\n")
  end
end
