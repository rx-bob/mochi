# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require "tree_sitter/class_extractor"

describe TreeSitter::ClassExtractor do
  it "extracts simple class name" do
    source = "class MyClass\nend\n"
    name = TreeSitter::ClassExtractor.class_name(source)
    _(name).must_equal "MyClass"
  end

  it "extracts class name with inheritance" do
    source = "class MyClass < ParentClass\n  def hello\n    puts \"hi\"\n  end\nend\n"
    name = TreeSitter::ClassExtractor.class_name(source)
    _(name).must_equal "MyClass"
  end

  it "extracts namespaced class name" do
    source = "class My::Nested::Class\n  def test\n  end\nend\n"
    name = TreeSitter::ClassExtractor.class_name(source)
    _(name).must_equal "My::Nested::Class"
  end

  it "extracts all class names from file with multiple classes" do
    source = [
      "class FirstClass",
      "end",
      "",
      "class SecondClass < BaseClass",
      "end",
      "",
      "module MyModule",
      "  class ThirdClass",
      "  end",
      "end",
    ].join("\n")
    names = TreeSitter::ClassExtractor.extract_class_names(source)
    _(names).must_equal ["FirstClass", "SecondClass", "ThirdClass"]
  end

  it "extracts superclass when present" do
    source = "class MyClass < ParentClass\nend\n"
    superclass = TreeSitter::ClassExtractor.extract_superclass(source)
    _(superclass).wont_be_nil
    _(superclass).must_equal "< ParentClass"
  end

  it "returns nil for superclass when absent" do
    source = "class MyClass\nend\n"
    superclass = TreeSitter::ClassExtractor.extract_superclass(source)
    _(superclass).must_be_nil
  end

  it "returns empty string when no class found" do
    source = "module Foo\nend\n"
    name = TreeSitter::ClassExtractor.class_name(source)
    _(name).must_equal ""
  end

  it "returns empty array when no classes found" do
    source = "x = 1 + 2\n"
    names = TreeSitter::ClassExtractor.extract_class_names(source)
    _(names).must_equal []
  end
end
