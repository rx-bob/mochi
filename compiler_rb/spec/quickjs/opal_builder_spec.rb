# typed: false
require_relative "../test_helper"
require_relative "../../src/quickjs/opal_builder"

class QuickJSOpalBuilderTest < Minitest::Test
  def test_build_joins_all_parts
    builder = QuickJS::Opal::Builder.new(include_runtime: false)
    builder.add_raw_js("// part 1")
    builder.add_raw_js("// part 2")
    result = builder.build
    assert_includes result, "// part 1"
    assert_includes result, "// part 2"
    builder.finalize
  end

  def test_compile_adds_compiled_part
    builder = QuickJS::Opal::Builder.new(include_runtime: false)
    builder.compile("1 + 2", "test.rb")
    result = builder.build
    assert_includes result, "$rb_plus"
    builder.finalize
  end

  def test_add_stdlib_loads_file
    builder = QuickJS::Opal::Builder.new(include_runtime: false)
    builder.add_stdlib("await")
    result = builder.build
    # await.js should contain some content
    refute_equal "", result.strip
    builder.finalize
  end

  def test_build_with_entry_point
    builder = QuickJS::Opal::Builder.new(include_runtime: false)
    builder.add_raw_js("// app")
    result = builder.build("lib/app.rb")
    assert_includes result, "Opal.require('lib/app');"
    builder.finalize
  end

  def test_compile_with_cache_uses_cache_when_available
    builder = QuickJS::Opal::Builder.new(include_runtime: false)

    cache = MockCache.new
    builder.compile_with_cache("3 + 4", "foo.rb", cache)
    result1 = builder.build

    # second call should hit cache
    builder2 = QuickJS::Opal::Builder.new(include_runtime: false)
    builder2.compile_with_cache("3 + 4", "foo.rb", cache)
    result2 = builder2.build

    assert_equal result1, result2
    assert cache.hits >= 1, "Expected cache to be hit"

    builder.finalize
    builder2.finalize
  end

  class MockCache
    attr_reader :hits

    def initialize
      @store = {}
      @hits = 0
    end

    def has(key)
      @store.key?(key)
    end

    def get(key)
      @hits += 1
      @store[key]
    end

    def put(key, value)
      @store[key] = value
    end
  end
end
