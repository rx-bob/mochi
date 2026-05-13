# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "inject_utils"

class AttributeHashGenerator
  extend T::Sig

  METHOD_PREFIX = "__mochi_attr_hash_"
  END_KEYWORD   = "end"
  FALLBACK_OFFSET = 3

  sig do
    params(
      ruby_code: String,
      class_name: String,
      hashes: T::Array[ExtractedAttributeHash]
    ).returns(String)
  end
  def self.inject_methods_into_class(ruby_code, class_name, hashes)
    return ruby_code if hashes.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(hashes)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  sig { params(hashes: T::Array[ExtractedAttributeHash]).returns(String) }
  def self.generate_all_methods(hashes)
    hashes.map { |hash| generate_method(hash) }.join("\n")
  end

  sig { params(hash: ExtractedAttributeHash).returns(String) }
  def self.generate_method(hash)
    method_name = "#{METHOD_PREFIX}#{hash.id}"
    attr_string = hash.original_string

    inner_hash = attr_string.delete_prefix("{{").delete_suffix("}}").strip

    lines = []
    lines << ""
    lines << "  # auto-generated attribute hash method"
    lines << "  def #{method_name}"
    lines << "    _hash = { #{inner_hash} }"
    lines << '    _hash.select { |k, v| v }.keys.join(" ")'
    lines << "  end"
    lines << ""

    lines.join("\n")
  end
end
