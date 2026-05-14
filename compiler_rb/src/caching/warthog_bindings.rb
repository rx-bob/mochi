# typed: false
# frozen_string_literal: true

require "ffi"

module WarthogBindings
  extend FFI::Library

  # Try multiple candidate paths for the WarthogDB library
  CANDIDATE_DIRS = [
    File.expand_path("../../../fragments/libs", __dir__),
    File.expand_path("../../fragments/libs", __dir__),
    File.expand_path("../fragments/libs", __dir__),
    "/usr/local/lib",
    "/opt/homebrew/lib",
  ].freeze

  def self.find_lib
    extensions = [".dylib", ".so", ".dll"]
    CANDIDATE_DIRS.each do |dir|
      extensions.each do |ext|
        path = File.join(dir, "libwarthogdb#{ext}")
        return path if File.exist?(path)
      end
    end
    "warthogdb"
  end

  ffi_lib find_lib

  # Database management
  attach_function :warthog_open, [:pointer, :uint32, :double, :uint32], :pointer
  attach_function :warthog_close, [:pointer], :void

  # CRUD operations
  attach_function :warthog_put, [:pointer, :pointer, :size_t, :pointer, :size_t], :int32
  attach_function :warthog_get, [:pointer, :pointer, :size_t, :pointer, :size_t, :pointer], :int32
  attach_function :warthog_delete, [:pointer, :pointer, :size_t], :int32

  # Snapshots
  attach_function :warthog_snapshot_open, [:pointer], :pointer
  attach_function :warthog_snapshot_close, [:pointer, :pointer], :void
  attach_function :warthog_snapshot_get, [:pointer, :pointer, :pointer, :size_t, :pointer, :size_t, :pointer], :int32

  # Iterators
  attach_function :warthog_iter_open, [:pointer], :pointer
  attach_function :warthog_snapshot_iter_open, [:pointer, :pointer], :pointer
  attach_function :warthog_iter_next, [:pointer, :pointer, :size_t, :pointer, :pointer, :size_t, :pointer], :int32
  attach_function :warthog_iter_close, [:pointer], :void
end
