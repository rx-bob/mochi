# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require "lexbor/bindings"

describe Lexbor do
  it "finds lexbor library" do
    path = LexborBindings.find_lib("lexbor")
    _(path).must_be_kind_of String
    _(path.end_with?(".dylib") || path.end_with?(".so") || path == "lexbor").must_equal true
  end

  describe Lexbor::Document do
    it "can parse simple html and get body" do
      doc = Lexbor::Document.new
      doc.parse("<div>hello</div>")
      body = doc.body
      _(body).wont_be_nil
      _(body).must_be_kind_of Lexbor::Node
      doc.destroy
    end

    it "can parse via class-level parse helper" do
      doc = Lexbor::Document.parse("<html><body><p>hi</p></body></html>")
      body = doc.body
      _(body).wont_be_nil
      doc.destroy
    end
  end

  describe Lexbor::Node do
    before do
      @doc = Lexbor::Document.new
    end

    after do
      @doc.destroy
    end

    it "reads tag_name for elements" do
      @doc.parse("<div>hello</div>")
      body = @doc.body
      children = body.children
      div = children.find { |c| c.tag_name == "div" }
      _(div).wont_be_nil
      _(div.tag_name).must_equal "div"
    end

    it "includes text nodes in children with tag_name _text" do
      @doc.parse("<div>hello</div>")
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      _(div).wont_be_nil
      text_node = div.children.find { |c| c.tag_name == "_text" }
      _(text_node).wont_be_nil
      _(text_node.tag_text).must_equal "hello"
    end

    it "includes comment nodes with tag_name _em_comment" do
      @doc.parse("<div><!-- if-anchor --></div>")
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      _(div).wont_be_nil
      comment = div.children.find { |c| c.tag_name == "_em_comment" }
      _(comment).wont_be_nil
      _(comment.tag_text).must_equal " if-anchor "
    end

    it "reads attributes" do
      @doc.parse('<div class="foo" id="bar">x</div>')
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      _(div).wont_be_nil
      _(div.attributes).must_equal({ "class" => "foo", "id" => "bar" })
    end

    it "removes attributes" do
      @doc.parse('<div class="foo" id="bar">x</div>')
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      div.attribute_remove("class")
      _(div.attributes.keys).wont_include "class"
      _(div.attributes).must_equal({ "id" => "bar" })
    end

    it "adds attributes" do
      @doc.parse('<div>x</div>')
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      div.attribute_add("data-x", "1")
      _(div.attributes).must_equal({ "data-x" => "1" })
    end

    it "serializes to html via to_html" do
      @doc.parse('<span>a</span>')
      body = @doc.body
      span = body.children.find { |c| c.tag_name == "span" }
      _(span.to_html).must_equal "<span>a</span>"
    end

    it "serializes children via inner_html" do
      @doc.parse('<div><span>a</span><p>b</p></div>')
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      _(div.inner_html).must_equal "<span>a</span><p>b</p>"
    end

    it "matches Crystal lexbor shard output for inner_html" do
      @doc.parse("<div class=\"wrapper\">\n  <h1>Count123: {count}</h1>\n  <button onclick=\"{increment}\">Increment</button>\n</div>")
      body = @doc.body
      div = body.children.find { |c| c.tag_name == "div" }
      _(div.inner_html).must_equal "\n  <h1>Count123: {count}</h1>\n  <button onclick=\"{increment}\">Increment</button>\n"
    end

    it "serializes body inner_html" do
      @doc.parse("<div>hello</div>")
      body = @doc.body
      _(body.inner_html).must_equal "<div>hello</div>"
    end
  end
end
