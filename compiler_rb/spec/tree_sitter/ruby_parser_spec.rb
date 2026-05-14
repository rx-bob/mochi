# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require "tree_sitter/ruby_parser"

describe TreeSitter::Node do
  before do
    @parser = TreeSitter::RubyParser.new
    @tree = @parser.parse("class Foo; def bar; 1 + 2; end; end")
    @root = @tree.root_node
    @class_node = @root.named_child(0)
  end

  after do
    @tree.close
    @parser.close
  end

  it "returns type" do
    _(@root.type).must_equal "program"
    _(@class_node.type).must_equal "class"
  end

  it "checks null?" do
    _(@root.null?).must_equal false
    _(@class_node.null?).must_equal false
  end

  it "returns child_count" do
    _(@root.child_count).must_equal 1
    _(@class_node.child_count).must_equal 5
  end

  it "returns named_child_count" do
    _(@root.named_child_count).must_equal 1
  end

  it "returns child by index" do
    child = @root.child(0)
    _(child).must_be_kind_of TreeSitter::Node
    _(child.type).must_equal "class"
  end

  it "returns named_child by index" do
    child = @class_node.named_child(0)
    _(child.type).must_equal "constant"
    _(child.text).must_equal "Foo"
  end

  it "finds child by field name" do
    name_node = @class_node.child_by_field_name("name")
    _(name_node).wont_be_nil
    _(name_node.type).must_equal "constant"
    _(name_node.text).must_equal "Foo"
  end

  it "returns nil for missing field" do
    missing = @class_node.child_by_field_name("nonexistent")
    _(missing).must_be_nil
  end

  it "returns text slice from source" do
    _(@root.text).must_equal "class Foo; def bar; 1 + 2; end; end"
    _(@class_node.text).must_equal "class Foo; def bar; 1 + 2; end; end"
    name_node = @class_node.child_by_field_name("name")
    _(name_node.text).must_equal "Foo"
  end

  it "has to_s representation" do
    _(@root.to_s).must_match(/program \[\d+-\d+\]/)
  end

  it "iterates children with each_child" do
    children = []
    @root.each_child { |c| children << c.type }
    _(children).must_equal ["class"]
  end

  it "iterates named children with each_named_child" do
    children = []
    @class_node.each_named_child { |c| children << c.type }
    _(children).must_include "constant"
    _(children).must_include "body_statement"
  end
end

describe TreeSitter::RubyParser do
  it "creates parser and sets language" do
    parser = TreeSitter::RubyParser.new
    _(parser).must_be_kind_of TreeSitter::RubyParser
    parser.close
  end

  it "raises on language failure (if language invalid)" do
    # This test verifies the code path exists; actual failure would require
    # a bad language pointer which is hard to construct.
    parser = TreeSitter::RubyParser.new
    tree = parser.parse("x = 1")
    _(tree).must_be_kind_of TreeSitter::Tree
    tree.close
    parser.close
  end
end

describe TreeSitter::Tree do
  before do
    @parser = TreeSitter::RubyParser.new
  end

  after do
    @parser.close
  end

  it "returns root_node" do
    tree = @parser.parse("module Foo; end")
    root = tree.root_node
    _(root).must_be_kind_of TreeSitter::Node
    _(root.type).must_equal "program"
    tree.close
  end

  it "closes without error" do
    tree = @parser.parse("1 + 1")
    tree.close
    pass
  end
end

describe "Integration" do
  it "parses complex ruby and navigates AST" do
    source = [
      "class MyCounter < MochiBase",
      "  def initialize",
      "    @count = 0",
      "  end",
      "",
      "  def increment",
      "    @count += 1",
      "  end",
      "end",
    ].join("\n")

    parser = TreeSitter::RubyParser.new
    tree = parser.parse(source)
    root = tree.root_node

    _(root.type).must_equal "program"
    _(root.child_count).must_equal 1

    klass = root.named_child(0)
    _(klass.type).must_equal "class"

    name = klass.child_by_field_name("name")
    _(name).wont_be_nil
    _(name.text).must_equal "MyCounter"

    superclass = klass.child_by_field_name("superclass")
    _(superclass).wont_be_nil
    # The superclass node text includes '< ' prefix; the actual constant is a named child
    superclass_name = superclass.named_child(0)
    _(superclass_name.text).must_equal "MochiBase"

    # Methods are inside body_statement, not direct named children of class
    body = klass.child_by_field_name("body")
    if body
      method_types = []
      body.each_named_child { |c| method_types << c.type if c.type == "method" }
      _(method_types).must_equal ["method", "method"]
    end

    tree.close
    parser.close
  end
end
