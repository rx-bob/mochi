# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "warthog_bindings"

class WarthogDB
  extend T::Sig

  class Error < StandardError; end
  class NotFoundError < Error; end
  class BufferTooSmallError < Error; end

  sig { returns(String) }
  attr_reader :path

  sig { params(path: String, max_file_size: Integer, compaction_threshold: Float, number_of_records: Integer).void }
  def initialize(
    path,
    max_file_size: 1024 * 1024 * 10,
    compaction_threshold: 0.7,
    number_of_records: 10000
  )
    @path = path
    @handle = T.let(WarthogBindings.warthog_open(
      path,
      max_file_size.to_i,
      compaction_threshold,
      number_of_records.to_i
    ), FFI::Pointer)
    @closed = T.let(false, T::Boolean)

    if @handle.null?
      raise Error.new("Failed to open WarthogDB at #{path}")
    end
  end

  sig { params(path: String, max_file_size: Integer, compaction_threshold: Float, number_of_records: Integer).returns(WarthogDB) }
  def self.open(path, max_file_size: 1024 * 1024 * 10, compaction_threshold: 0.7, number_of_records: 10000)
    new(path, max_file_size: max_file_size, compaction_threshold: compaction_threshold, number_of_records: number_of_records)
  end

  sig { params(key: String, value: String).void }
  def put(key, value)
    result = WarthogBindings.warthog_put(
      @handle,
      key,
      key.bytesize,
      value,
      value.bytesize
    )

    if result != 0
      raise Error.new("Failed to put key: #{key}")
    end
  end

  sig { params(key: String).returns(T.nilable(String)) }
  def get(key)
    bytes = get_bytes(key)
    bytes && String.new(bytes)
  end

  sig { params(key: String, initial_buffer_size: Integer).returns(T.nilable(String)) }
  def get_bytes(key, initial_buffer_size: 4096)
    buffer = FFI::MemoryPointer.new(:char, initial_buffer_size)
    out_len_ptr = FFI::MemoryPointer.new(:size_t, 1)

    result = WarthogBindings.warthog_get(
      @handle,
      key,
      key.bytesize,
      buffer,
      initial_buffer_size,
      out_len_ptr
    )

    case result
    when 0
      out_len = out_len_ptr.read_uint64
      buffer.get_bytes(0, out_len)
    when 1
      nil
    when 2
      out_len = out_len_ptr.read_uint64
      get_bytes(key, initial_buffer_size: out_len * 2)
    else
      raise Error.new("Failed to get key")
    end
  end

  sig { params(key: String, value: String).void }
  def []=(key, value)
    put(key, value)
  end

  sig { params(key: String).returns(String) }
  def [](key)
    get(key) || raise(NotFoundError.new("Key not found: #{key}"))
  end

  sig { params(key: String).returns(T.nilable(String)) }
  def fetch(key)
    get(key)
  end

  sig { params(key: String).void }
  def delete(key)
    result = WarthogBindings.warthog_delete(
      @handle,
      key,
      key.bytesize
    )

    if result != 0
      raise Error.new("Failed to delete key: #{key}")
    end
  end

  sig { returns(Snapshot) }
  def snapshot
    Snapshot.new(self)
  end

  sig { params(block: T.proc.params(key: String, value: String).void).void }
  def each(&block)
    iterator = Iterator.new(self)
    begin
      iterator.each { |k, v| block.call(k, v) }
    ensure
      iterator.close
    end
  end

  sig { void }
  def close
    return if @closed
    WarthogBindings.warthog_close(@handle)
    @closed = true
  end

  class Snapshot
    extend T::Sig

    sig { params(db: WarthogDB).void }
    def initialize(db)
      @db = db
      @handle = T.let(WarthogBindings.warthog_snapshot_open(db.instance_variable_get(:@handle)), FFI::Pointer)
      @closed = T.let(false, T::Boolean)

      if @handle.null?
        raise Error.new("Failed to open snapshot")
      end
    end

    sig { params(key: String).returns(T.nilable(String)) }
    def get(key)
      bytes = get_bytes(key)
      bytes && String.new(bytes)
    end

    sig { params(key: String, initial_buffer_size: Integer).returns(T.nilable(String)) }
    def get_bytes(key, initial_buffer_size: 4096)
      db_handle = @db.instance_variable_get(:@handle)
      buffer = FFI::MemoryPointer.new(:char, initial_buffer_size)
      out_len_ptr = FFI::MemoryPointer.new(:size_t, 1)

      result = WarthogBindings.warthog_snapshot_get(
        db_handle,
        @handle,
        key,
        key.bytesize,
        buffer,
        initial_buffer_size,
        out_len_ptr
      )

      case result
      when 0
        out_len = out_len_ptr.read_uint64
        buffer.get_bytes(0, out_len)
      when 1
        nil
      when 2
        out_len = out_len_ptr.read_uint64
        get_bytes(key, initial_buffer_size: out_len * 2)
      else
        raise Error.new("Failed to get key from snapshot")
      end
    end

    sig { params(key: String).returns(T.nilable(String)) }
    def fetch(key)
      get(key)
    end

    sig { params(key: String).returns(String) }
    def [](key)
      get(key) || raise(NotFoundError.new("Key not found in snapshot: #{key}"))
    end

    sig { params(block: T.proc.params(key: String, value: String).void).void }
    def each(&block)
      iterator = Iterator.new(@db, self)
      begin
        iterator.each { |k, v| block.call(k, v) }
      ensure
        iterator.close
      end
    end

    sig { void }
    def close
      return if @closed
      db_handle = @db.instance_variable_get(:@handle)
      WarthogBindings.warthog_snapshot_close(db_handle, @handle)
      @closed = true
    end
  end

  class Iterator
    extend T::Sig

    sig { params(db: WarthogDB, snapshot: T.nilable(Snapshot)).void }
    def initialize(db, snapshot = nil)
      @db = db
      db_handle = db.instance_variable_get(:@handle)
      @handle = T.let(
        if snapshot
          WarthogBindings.warthog_snapshot_iter_open(db_handle, snapshot.instance_variable_get(:@handle))
        else
          WarthogBindings.warthog_iter_open(db_handle)
        end,
        FFI::Pointer
      )
      @closed = T.let(false, T::Boolean)

      if @handle.null?
        raise Error.new("Failed to open iterator")
      end
    end

    sig { params(block: T.proc.params(key: String, value: String).void).void }
    def each(&block)
      key_buffer = FFI::MemoryPointer.new(:char, 4096)
      val_buffer = FFI::MemoryPointer.new(:char, 4096)
      key_len_ptr = FFI::MemoryPointer.new(:size_t, 1)
      val_len_ptr = FFI::MemoryPointer.new(:size_t, 1)

      loop do
        result = WarthogBindings.warthog_iter_next(
          @handle,
          key_buffer,
          4096,
          key_len_ptr,
          val_buffer,
          4096,
          val_len_ptr
        )

        case result
        when 1
          break
        when 0
          key_len = key_len_ptr.read_uint64
          val_len = val_len_ptr.read_uint64
          key = key_buffer.get_bytes(0, key_len)
          value = val_buffer.get_bytes(0, val_len)
          block.call(key, value)
        when 2
          key_len = key_len_ptr.read_uint64
          val_len = val_len_ptr.read_uint64
          new_key_size = key_len > 4096 ? key_len : 4096 * 2
          new_val_size = val_len > 4096 ? val_len : 4096 * 2
          key_buffer = FFI::MemoryPointer.new(:char, new_key_size)
          val_buffer = FFI::MemoryPointer.new(:char, new_val_size)
          next
        else
          raise Error.new("Iterator error")
        end
      end
    end

    sig { void }
    def close
      return if @closed
      WarthogBindings.warthog_iter_close(@handle)
      @closed = true
    end
  end
end
