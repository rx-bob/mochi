# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/caching/warthog_bindings"

class WarthogBindingsSpec < Minitest::Test
  def db_path
    "/tmp/test_warthog_db_#{Time.now.to_f}_#{rand(10000)}"
  end

  def test_opens_and_closes_database
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024 * 10,
      0.7,
      10_000
    )
    refute_nil handle
    WarthogBindings.warthog_close(handle)
  end

  def test_puts_and_gets_a_value
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024 * 10,
      0.7,
      10_000
    )
    refute_nil handle

    key = "test_key"
    value = "test_value"

    result = WarthogBindings.warthog_put(
      handle,
      key,
      key.bytesize,
      value,
      value.bytesize
    )
    assert_equal 0, result

    buffer = FFI::MemoryPointer.new(:char, 1024)
    out_len = FFI::MemoryPointer.new(:size_t)

    get_result = WarthogBindings.warthog_get(
      handle,
      key,
      key.bytesize,
      buffer,
      buffer.size,
      out_len
    )

    assert_equal 0, get_result
    assert_equal value.bytesize, out_len.read_uint64
    assert_equal value, buffer.read_string(value.bytesize)

    WarthogBindings.warthog_close(handle)
  end

  def test_returns_not_found_for_missing_key
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024 * 10,
      0.7,
      10_000
    )
    refute_nil handle

    key = "missing_key"
    buffer = FFI::MemoryPointer.new(:char, 1024)
    out_len = FFI::MemoryPointer.new(:size_t)

    get_result = WarthogBindings.warthog_get(
      handle,
      key,
      key.bytesize,
      buffer,
      buffer.size,
      out_len
    )

    assert_equal 1, get_result

    WarthogBindings.warthog_close(handle)
  end

  def test_deletes_a_value
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024 * 10,
      0.7,
      10_000
    )
    refute_nil handle

    key = "delete_test"
    value = "to_be_deleted"

    WarthogBindings.warthog_put(
      handle,
      key,
      key.bytesize,
      value,
      value.bytesize
    )

    delete_result = WarthogBindings.warthog_delete(
      handle,
      key,
      key.bytesize
    )
    assert_equal 0, delete_result

    buffer = FFI::MemoryPointer.new(:char, 1024)
    out_len = FFI::MemoryPointer.new(:size_t)

    get_result = WarthogBindings.warthog_get(
      handle,
      key,
      key.bytesize,
      buffer,
      buffer.size,
      out_len
    )

    assert_equal 1, get_result

    WarthogBindings.warthog_close(handle)
  end

  def test_opens_and_closes_snapshots
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024,
      0.7,
      10_000
    )
    refute_nil handle

    key = "test_key"
    value = "test_value"

    WarthogBindings.warthog_put(
      handle,
      key,
      key.bytesize,
      value,
      value.bytesize
    )

    snapshot = WarthogBindings.warthog_snapshot_open(handle)
    refute_nil snapshot

    buffer = FFI::MemoryPointer.new(:char, 1024)
    out_len = FFI::MemoryPointer.new(:size_t)

    snapshot_get_result = WarthogBindings.warthog_snapshot_get(
      handle,
      snapshot,
      key,
      key.bytesize,
      buffer,
      buffer.size,
      out_len
    )

    assert([0, 1].include?(snapshot_get_result))

    WarthogBindings.warthog_snapshot_close(handle, snapshot)
    WarthogBindings.warthog_close(handle)
  end

  def test_iterates_over_key_value_pairs
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024 * 10,
      0.7,
      10_000
    )
    refute_nil handle

    entries = {
      "key1" => "value1",
      "key2" => "value2",
      "key3" => "value3",
    }

    entries.each do |key, value|
      WarthogBindings.warthog_put(
        handle,
        key,
        key.bytesize,
        value,
        value.bytesize
      )
    end

    iter = WarthogBindings.warthog_iter_open(handle)
    refute_nil iter

    found_entries = {}
    key_buffer = FFI::MemoryPointer.new(:char, 1024)
    val_buffer = FFI::MemoryPointer.new(:char, 1024)
    key_len = FFI::MemoryPointer.new(:size_t)
    val_len = FFI::MemoryPointer.new(:size_t)

    loop do
      result = WarthogBindings.warthog_iter_next(
        iter,
        key_buffer,
        key_buffer.size,
        key_len,
        val_buffer,
        val_buffer.size,
        val_len
      )

      break if result == 1
      assert_equal 0, result

      k = key_buffer.read_string(key_len.read_uint64)
      v = val_buffer.read_string(val_len.read_uint64)
      found_entries[k] = v
    end

    assert_equal entries, found_entries

    WarthogBindings.warthog_iter_close(iter)
    WarthogBindings.warthog_close(handle)
  end

  def test_opens_and_closes_snapshot_iterators
    path = db_path
    handle = WarthogBindings.warthog_open(
      path,
      1024 * 1024,
      0.7,
      10_000
    )
    refute_nil handle

    entries = {
      "key1" => "value1",
      "key2" => "value2",
      "key3" => "value3",
    }

    entries.each do |key, value|
      WarthogBindings.warthog_put(
        handle,
        key,
        key.bytesize,
        value,
        value.bytesize
      )
    end

    snapshot = WarthogBindings.warthog_snapshot_open(handle)
    refute_nil snapshot

    iter = WarthogBindings.warthog_snapshot_iter_open(handle, snapshot)
    refute_nil iter

    key_buffer = FFI::MemoryPointer.new(:char, 1024)
    val_buffer = FFI::MemoryPointer.new(:char, 1024)
    key_len = FFI::MemoryPointer.new(:size_t)
    val_len = FFI::MemoryPointer.new(:size_t)

    loop do
      result = WarthogBindings.warthog_iter_next(
        iter,
        key_buffer,
        key_buffer.size,
        key_len,
        val_buffer,
        val_buffer.size,
        val_len
      )

      break if result == 1
    end

    WarthogBindings.warthog_iter_close(iter)
    WarthogBindings.warthog_snapshot_close(handle, snapshot)
    WarthogBindings.warthog_close(handle)
  end
end
