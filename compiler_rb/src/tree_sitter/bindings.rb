# typed: false
# frozen_string_literal: true

require "ffi"
require "sorbet-runtime"

module TreeSitterCore
  extend FFI::Library

  # Try multiple candidate paths for the tree-sitter libraries
  CANDIDATE_DIRS = T.let([
    File.expand_path("../../../fragments/libs", __dir__),
    File.expand_path("../../fragments/libs", __dir__),
    File.expand_path("../fragments/libs", __dir__),
    "/usr/local/lib",
    "/opt/homebrew/lib",
  ].freeze, T::Array[String])

  # Helper to find a library file with platform-appropriate extensions
  def self.find_lib(name)
    extensions = [".dylib", ".so", ".dll"]
    CANDIDATE_DIRS.each do |dir|
      extensions.each do |ext|
        path = File.join(dir, "lib#{name}#{ext}")
        return path if File.exist?(path)
      end
    end
    # fallback: let ffi_lib try to resolve it system-wide
    name
  end

  ffi_lib find_lib("tree-sitter")

  # TSPoint struct
  class TSPoint < FFI::Struct
    layout :row, :uint32,
           :column, :uint32
  end

  # TSNode struct (32 bytes, passed by value)
  class TSNode < FFI::Struct
    layout :context, [:uint32, 4],
           :id, :pointer,
           :tree, :pointer
  end

  # Parser functions
  attach_function :ts_parser_new, [], :pointer
  attach_function :ts_parser_delete, [:pointer], :void
  attach_function :ts_parser_set_language, [:pointer, :pointer], :bool
  attach_function :ts_parser_parse_string, [:pointer, :pointer, :string, :uint32], :pointer

  # Tree functions
  attach_function :ts_tree_root_node, [:pointer], TSNode.by_value
  attach_function :ts_tree_delete, [:pointer], :void

  # Node functions
  attach_function :ts_node_type, [TSNode.by_value], :string
  attach_function :ts_node_is_null, [TSNode.by_value], :bool
  attach_function :ts_node_child_count, [TSNode.by_value], :uint32
  attach_function :ts_node_named_child_count, [TSNode.by_value], :uint32
  attach_function :ts_node_child, [TSNode.by_value, :uint32], TSNode.by_value
  attach_function :ts_node_named_child, [TSNode.by_value, :uint32], TSNode.by_value
  attach_function :ts_node_child_by_field_name, [TSNode.by_value, :string, :uint32], TSNode.by_value
  attach_function :ts_node_start_byte, [TSNode.by_value], :uint32
  attach_function :ts_node_end_byte, [TSNode.by_value], :uint32
  attach_function :ts_node_start_point, [TSNode.by_value], TSPoint.by_value
  attach_function :ts_node_end_point, [TSNode.by_value], TSPoint.by_value
  attach_function :ts_node_string, [TSNode.by_value], :pointer
end

module TreeSitterRuby
  extend FFI::Library

  CANDIDATE_DIRS = TreeSitterCore::CANDIDATE_DIRS

  def self.find_lib(name)
    TreeSitterCore.find_lib(name)
  end

  ffi_lib find_lib("tree-sitter-ruby")

  attach_function :tree_sitter_ruby, [], :pointer
end

# Unifying module for backwards compat and cleaner interface
module TreeSitterBindings
  extend T::Sig

  TSNode = TreeSitterCore::TSNode
  TSPoint = TreeSitterCore::TSPoint

  def self.method_missing(method_name, *args, &block)
    if TreeSitterCore.respond_to?(method_name)
      TreeSitterCore.send(method_name, *args, &block)
    elsif TreeSitterRuby.respond_to?(method_name)
      TreeSitterRuby.send(method_name, *args, &block)
    else
      super
    end
  end

  def self.respond_to_missing?(method_name, include_private = false)
    TreeSitterCore.respond_to?(method_name) || TreeSitterRuby.respond_to?(method_name) || super
  end
end
