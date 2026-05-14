# typed: false
require_relative "../test_helper"
require_relative "../../src/caching/warthog_bindings"
require_relative "../../src/caching/warthogdb"

class WarthogDBTest < Minitest::Test
  def test_creates_and_closes_database
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)
    assert_equal db_path, db.path
    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_puts_and_gets_values
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db.put("key1", "value1")
    assert_equal "value1", db.get("key1")

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_uses_array_syntax_for_put_and_get
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db["key2"] = "value2"
    assert_equal "value2", db["key2"]
    assert_equal "value2", db.fetch("key2")

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_returns_nil_for_missing_keys
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    assert_nil db.get("missing")
    assert_nil db.fetch("missing")

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_raises_not_found_error_for_missing_keys_with_get_bang
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    assert_raises(WarthogDB::NotFoundError) do
      db["missing"]
    end

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_deletes_keys
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db["key"] = "value"
    assert_equal "value", db["key"]

    db.delete("key")
    assert_nil db.fetch("key")

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_iterates_over_key_value_pairs
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    entries = { "a" => "value_a", "b" => "value_b", "c" => "value_c" }
    entries.each do |k, v|
      db[k] = v
    end

    found = {}
    db.each do |k, v|
      found[k] = v
    end

    assert_equal entries, found

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_creates_snapshots
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db["key1"] = "value1"

    snapshot = db.snapshot
    refute_nil snapshot
    snapshot.close

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_gets_values_from_snapshots
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db["key1"] = "value1"

    snapshot = db.snapshot

    result = snapshot["key1"]
    assert_equal "value1", result

    snapshot.close
    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_iterates_over_snapshot
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    db["a"] = "1"
    db["b"] = "2"

    snapshot = db.snapshot

    found = {}
    snapshot.each do |k, v|
      found[k] = v
    end

    snapshot.close
    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_handles_large_values
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.new(db_path)

    large_value = "x" * 100_000
    db["large"] = large_value
    assert_equal large_value, db["large"]

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end

  def test_uses_open_class_method
    db_path = "/tmp/warthog_spec_#{Time.now.to_i}_#{rand(10000)}"
    db = WarthogDB.open(db_path)

    db["test"] = "value"
    assert_equal "value", db["test"]

    db.close
  ensure
    FileUtils.rm_rf(db_path) if defined?(db_path)
  end
end
