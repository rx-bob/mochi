# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../data_models/ruby_def"
require_relative "../tree_sitter/ruby_parser"
require_relative "../tree_sitter/class_extractor"
require_relative "../tree_sitter/property_extractor"
require_relative "../tree_sitter/imports_extractor"
require_relative "../tree_sitter/method_body_extractor"
require_relative "../tree_sitter/string_extractor"

class RubyUnderstander
  extend T::Sig

  sig { params(body: T::Array[String], name: String).returns(String) }
  def self.extract_raw_string_from_def_body(body, name)
    TreeSitter::StringExtractor.extract_raw_string_from_def_body(body, name)
  end

  sig { params(code: String).returns(String) }
  def self.class_name(code)
    TreeSitter::ClassExtractor.class_name(code)
  end

  sig { params(rb_file: String).returns(T::Array[String]) }
  def self.get_imports(rb_file)
    TreeSitter::ImportsExtractor.extract_imports(rb_file)
  end

  sig { params(rb_file: String, cls_name: String).returns(T::Hash[String, RubyDef]) }
  def self.extract_method_bodies(rb_file, cls_name)
    TreeSitter::MethodBodyExtractor.extract_method_bodies(rb_file, cls_name)
  end

  sig { params(rb_file: String, cls_name: String).returns(T.nilable(String)) }
  def self.get_cmp_name(rb_file, cls_name)
    TreeSitter::PropertyExtractor.extract_property(rb_file, "@tag_name")
  end
end
