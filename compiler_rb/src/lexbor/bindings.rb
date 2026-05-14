# typed: false
# frozen_string_literal: true

require "ffi"
require "sorbet-runtime"

# Low-level FFI bindings to the Lexbor C library
module LexborBindings
  extend FFI::Library

  # Try multiple candidate paths for the lexbor library
  CANDIDATE_DIRS = T.let([
    File.expand_path("../../../compiler/lib/lexbor/src/ext/lexbor-c/build", __dir__),
    File.expand_path("../../compiler/lib/lexbor/src/ext/lexbor-c/build", __dir__),
    "/usr/local/lib",
    "/opt/homebrew/lib",
  ].freeze, T::Array[String])

  def self.find_lib(name)
    extensions = [".dylib", ".so", ".dll"]
    CANDIDATE_DIRS.each do |dir|
      extensions.each do |ext|
        path = File.join(dir, "lib#{name}#{ext}")
        return path if File.exist?(path)
      end
    end
    name
  end

  ffi_lib find_lib("lexbor")

  # Document
  attach_function :lxb_html_document_create, [], :pointer
  attach_function :lxb_html_document_parse, [:pointer, :pointer, :size_t], :int
  attach_function :lxb_html_document_destroy, [:pointer], :pointer
  attach_function :lxb_html_document_body_element_noi, [:pointer], :pointer
  attach_function :lxb_html_document_head_element_noi, [:pointer], :pointer
  attach_function :lxb_dom_document_element_noi, [:pointer], :pointer

  # Node info / navigation
  attach_function :lxb_dom_node_tag_id_noi, [:pointer], :size_t
  attach_function :lxb_dom_node_first_child_noi, [:pointer], :pointer
  attach_function :lxb_dom_node_next_noi, [:pointer], :pointer
  attach_function :lxb_dom_node_prev_noi, [:pointer], :pointer
  attach_function :lxb_dom_node_parent_noi, [:pointer], :pointer
  attach_function :lxb_dom_node_last_child_noi, [:pointer], :pointer
  attach_function :lxb_dom_node_text_content, [:pointer, :pointer], :pointer

  # Element names
  attach_function :lxb_dom_element_qualified_name, [:pointer, :pointer], :pointer
  attach_function :lxb_dom_element_local_name, [:pointer, :pointer], :pointer
  attach_function :lxb_dom_element_tag_name, [:pointer, :pointer], :pointer

  # Attributes
  attach_function :lxb_dom_element_first_attribute_noi, [:pointer], :pointer
  attach_function :lxb_dom_element_next_attribute_noi, [:pointer], :pointer
  attach_function :lxb_dom_attr_local_name_noi, [:pointer, :pointer], :pointer
  attach_function :lxb_dom_attr_value_noi, [:pointer, :pointer], :pointer
  attach_function :lxb_dom_element_set_attribute, [:pointer, :pointer, :size_t, :pointer, :size_t], :pointer
  attach_function :lxb_dom_element_remove_attribute, [:pointer, :pointer, :size_t], :int

  # Serialization
  callback :lxb_html_serialize_cb_f, [:pointer, :size_t, :pointer], :int
  attach_function :lxb_html_serialize_tree_cb, [:pointer, :lxb_html_serialize_cb_f, :pointer], :int
end

module Lexbor
  # Thin wrapper around a Lexbor document
  class Document
    def initialize
      @doc = LexborBindings.lxb_html_document_create
      raise "Failed to create HTML Document" if @doc.null?
    end

    def self.parse(html)
      new.tap { |d| d.parse(html) }
    end

    def parse(html)
      status = LexborBindings.lxb_html_document_parse(@doc, html, html.bytesize)
      raise "parse error #{status}" unless status == 0
      self
    end

    def body
      el = LexborBindings.lxb_html_document_body_element_noi(@doc)
      Lexbor::Node.new(self, el) unless el.null?
    end

    def root
      el = LexborBindings.lxb_dom_document_element_noi(@doc)
      Lexbor::Node.new(self, el) unless el.null?
    end

    def head
      el = LexborBindings.lxb_html_document_head_element_noi(@doc)
      Lexbor::Node.new(self, el) unless el.null?
    end

    def destroy
      LexborBindings.lxb_html_document_destroy(@doc) unless @doc.null?
      @doc = FFI::Pointer::NULL
    end

    # Serialize the full document to an HTML string
    def to_html
      root&.to_html || ""
    end

    # Serialize a node's children to an HTML string
    def self.inner_html(node)
      node.inner_html
    end
  end

  # Wrapper around a single Lexbor DOM node
  class Node
    # Tag IDs from Crystal source lexbor/lib/constants.cr
    TAG_UNDEF       = 0x0000
    TAG_END_OF_FILE = 0x0001
    TAG_TEXT        = 0x0002
    TAG_DOCUMENT    = 0x0003
    TAG_EM_COMMENT  = 0x0004
    TAG_EM_DOCTYPE  = 0x0005

    # Special text/comment nodes get symbolic names matching Crystal shard
    TAG_ID_TO_NAME = {
      TAG_TEXT       => "_text",
      TAG_EM_COMMENT => "_em_comment",
      TAG_EM_DOCTYPE => "_em_doctype",
    }.freeze

    attr_reader :document, :element

    def initialize(document, element)
      @document = document
      @element = element
    end

    def tag_id
      LexborBindings.lxb_dom_node_tag_id_noi(@element)
    end

    def tag_name
      special = TAG_ID_TO_NAME[tag_id]
      return special if special

      ptr = FFI::MemoryPointer.new(:uint64, 1)
      raw = LexborBindings.lxb_dom_element_qualified_name(@element, ptr)
      len = ptr.read_uint64
      raw.get_bytes(0, len)
    end

    def tag_text
      ptr = FFI::MemoryPointer.new(:uint64, 1)
      raw = LexborBindings.lxb_dom_node_text_content(@element, ptr)
      return nil if raw.null?

      len = ptr.read_uint64
      raw.get_bytes(0, len)
    end

    def children
      result = []
      child = LexborBindings.lxb_dom_node_first_child_noi(@element)
      until child.null?
        result << Lexbor::Node.new(@document, child)
        child = LexborBindings.lxb_dom_node_next_noi(child)
      end
      result
    end

    def attributes
      result = {}
      return result if [TAG_TEXT, TAG_EM_COMMENT, TAG_EM_DOCTYPE].include?(tag_id)

      attr = LexborBindings.lxb_dom_element_first_attribute_noi(@element)
      until attr.null?
        key = read_attr_name(attr)
        value = read_attr_value(attr)
        result[key] = value
        attr = LexborBindings.lxb_dom_element_next_attribute_noi(attr)
      end
      result
    end

    def attribute_remove(name)
      LexborBindings.lxb_dom_element_remove_attribute(@element, name, name.bytesize)
    end

    def attribute_add(key, value)
      LexborBindings.lxb_dom_element_set_attribute(
        @element,
        key, key.bytesize,
        value, value.bytesize
      )
    end

    # Serialize this node and its children to an HTML string
    def to_html
      buffer = +""
      cb = proc do |data, length, _ctx|
        buffer.concat(data.get_bytes(0, length)) unless data.null? || length == 0
        0 # LXB_STATUS_OK
      end

      status = LexborBindings.lxb_html_serialize_tree_cb(@element, cb, nil)
      raise "serialization error #{status}" unless status == 0

      buffer
    end

    # Serialize children only (same as Crystal Node#inner_html)
    def inner_html
      children.map(&:to_html).join
    end

    # Return true if this is a regular element node (not text/comment/doctype)
    def element?
      !["_text", "_em_comment", "_em_doctype"].include?(tag_name)
    end

    # Recursively collect all descendant element nodes
    def all_elements
      result = []
      walk_tree do |node, _level|
        result << node if node.element?
      end
      result
    end

    # Depth-first walk over this node and all descendants
    def walk_tree(level = 0, &block)
      yield self, level
      children.each { |child| child.walk_tree(level + 1, &block) }
    end

    private

    def read_attr_name(attr)
      ptr = FFI::MemoryPointer.new(:size_t, 1)
      raw = LexborBindings.lxb_dom_attr_local_name_noi(attr, ptr)
      len = ptr.get_uint64(0)
      raw.get_bytes(0, len)
    end

    def read_attr_value(attr)
      ptr = FFI::MemoryPointer.new(:size_t, 1)
      raw = LexborBindings.lxb_dom_attr_value_noi(attr, ptr)
      return "" if raw.null?

      len = ptr.get_uint64(0)
      raw.get_bytes(0, len)
    end
  end
end
