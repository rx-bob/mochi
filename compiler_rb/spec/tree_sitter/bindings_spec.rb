# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require "tree_sitter/bindings"

describe TreeSitterBindings do
  it "exposes all core functions" do
    assert TreeSitterBindings.respond_to?(:ts_parser_new)
    assert TreeSitterBindings.respond_to?(:ts_parser_delete)
    assert TreeSitterBindings.respond_to?(:ts_parser_set_language)
    assert TreeSitterBindings.respond_to?(:ts_parser_parse_string)
    assert TreeSitterBindings.respond_to?(:ts_tree_root_node)
    assert TreeSitterBindings.respond_to?(:ts_tree_delete)
    assert TreeSitterBindings.respond_to?(:ts_node_type)
    assert TreeSitterBindings.respond_to?(:ts_node_is_null)
    assert TreeSitterBindings.respond_to?(:ts_node_child_count)
    assert TreeSitterBindings.respond_to?(:ts_node_named_child_count)
    assert TreeSitterBindings.respond_to?(:ts_node_child)
    assert TreeSitterBindings.respond_to?(:ts_node_named_child)
    assert TreeSitterBindings.respond_to?(:ts_node_child_by_field_name)
    assert TreeSitterBindings.respond_to?(:ts_node_start_byte)
    assert TreeSitterBindings.respond_to?(:ts_node_end_byte)
    assert TreeSitterBindings.respond_to?(:ts_node_start_point)
    assert TreeSitterBindings.respond_to?(:ts_node_end_point)
    assert TreeSitterBindings.respond_to?(:ts_node_string)
    assert TreeSitterBindings.respond_to?(:tree_sitter_ruby)
  end

  it "can create and delete a parser" do
    parser = TreeSitterBindings.ts_parser_new
    _(parser).wont_be_nil
    _(parser).must_be_kind_of FFI::Pointer
    _(parser.null?).must_equal false
    TreeSitterBindings.ts_parser_delete(parser)
  end

  it "can set ruby language" do
    parser = TreeSitterBindings.ts_parser_new
    lang = TreeSitterBindings.tree_sitter_ruby
    _(lang).wont_be_nil
    _(lang).must_be_kind_of FFI::Pointer
    result = TreeSitterBindings.ts_parser_set_language(parser, lang)
    _(result).must_equal true
    TreeSitterBindings.ts_parser_delete(parser)
  end

  it "can parse a simple ruby class" do
    parser = TreeSitterBindings.ts_parser_new
    lang = TreeSitterBindings.tree_sitter_ruby
    TreeSitterBindings.ts_parser_set_language(parser, lang)

    source = "class Foo; end"
    tree = TreeSitterBindings.ts_parser_parse_string(parser, nil, source, source.bytesize)
    _(tree).wont_be_nil
    _(tree).must_be_kind_of FFI::Pointer

    root = TreeSitterBindings.ts_tree_root_node(tree)
    _(TreeSitterBindings.ts_node_type(root)).must_equal "program"
    _(TreeSitterBindings.ts_node_child_count(root)).must_equal 1
    _(TreeSitterBindings.ts_node_is_null(root)).must_equal false

    child = TreeSitterBindings.ts_node_child(root, 0)
    _(TreeSitterBindings.ts_node_type(child)).must_equal "class"

    # Byte range
    _(TreeSitterBindings.ts_node_start_byte(root)).must_equal 0
    _(TreeSitterBindings.ts_node_end_byte(root)).must_equal source.bytesize

    TreeSitterBindings.ts_tree_delete(tree)
    TreeSitterBindings.ts_parser_delete(parser)
  end

  it "can access named children" do
    parser = TreeSitterBindings.ts_parser_new
    lang = TreeSitterBindings.tree_sitter_ruby
    TreeSitterBindings.ts_parser_set_language(parser, lang)

    source = "x = 1"
    tree = TreeSitterBindings.ts_parser_parse_string(parser, nil, source, source.bytesize)
    root = TreeSitterBindings.ts_tree_root_node(tree)
    _(TreeSitterBindings.ts_node_named_child_count(root)).must_equal 1

    stmt = TreeSitterBindings.ts_node_named_child(root, 0)
    _(TreeSitterBindings.ts_node_type(stmt)).must_equal "assignment"

    TreeSitterBindings.ts_tree_delete(tree)
    TreeSitterBindings.ts_parser_delete(parser)
  end

  it "exposes TSNode and TSPoint classes" do
    _(TreeSitterBindings::TSNode).must_be_kind_of Class
    _(TreeSitterBindings::TSPoint).must_be_kind_of Class
    _(TreeSitterBindings::TSNode < FFI::Struct).must_equal true
    _(TreeSitterBindings::TSPoint < FFI::Struct).must_equal true
  end

  it "has find_lib helper that locates tree-sitter libraries" do
    _(TreeSitterCore.find_lib("tree-sitter")).must_be_kind_of String
    _(TreeSitterCore.find_lib("tree-sitter-ruby")).must_be_kind_of String
  end
end
