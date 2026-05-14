# typed: false
require_relative "../test_helper"
require_relative "../../src/opal/opal_runtime_generator"

class OpalRuntimeGeneratorTest < Minitest::Test
  def setup
    @generator = OpalRuntimeGenerator.new
  end

  def test_get_runtime_file_path
    assert_equal "/tmp/build/runtime.js", @generator.get_runtime_file_path("/tmp/build")
  end

  def test_resolve_path_finds_existing_file
    result = @generator.resolve_path("../fragments/vendor/runtime.js", ["../fragments/vendor/runtime.js"])
    assert File.exist?(result), "Expected #{result} to exist"
  end

  def test_resolve_path_finds_mochi_component_js
    result = @generator.resolve_path("src/js/runtime/mochi_component.js", ["src/js/runtime/mochi_component.js"])
    assert File.exist?(result), "Expected #{result} to exist"
  end

  def test_resolve_path_finds_signal_js
    result = @generator.resolve_path("src/js/runtime/signal.js", ["src/js/runtime/signal.js"])
    assert File.exist?(result), "Expected #{result} to exist"
  end

  def test_generate_writes_runtime_js
    Dir.mktmpdir do |build_dir|
      @generator.generate(build_dir)

      output_path = "#{build_dir}/runtime.js"
      assert File.exist?(output_path), "Expected runtime.js to be created"

      content = File.read(output_path)
      assert content.length > 0, "Expected non-empty content"
    end
  end

  def test_generate_concatenates_files_in_order
    Dir.mktmpdir do |build_dir|
      @generator.generate(build_dir)

      content = File.read("#{build_dir}/runtime.js")

      base_runtime = File.read(@generator.resolve_path("../fragments/vendor/runtime.js", ["../fragments/vendor/runtime.js"]))
      signal_rt = File.read(@generator.resolve_path("src/js/runtime/signal.js", ["src/js/runtime/signal.js"]))
      mochi_comp = File.read(@generator.resolve_path("src/js/runtime/mochi_component.js", ["src/js/runtime/mochi_component.js"]))

      expected = base_runtime + "\n" + signal_rt + "\n" + mochi_comp
      assert_equal expected, content
    end
  end

  def test_generate_contains_base_runtime_content
    Dir.mktmpdir do |build_dir|
      @generator.generate(build_dir)

      content = File.read("#{build_dir}/runtime.js")
      base_runtime = File.read(@generator.resolve_path("../fragments/vendor/runtime.js", ["../fragments/vendor/runtime.js"]))

      assert_includes content, base_runtime[0..100]
    end
  end

  def test_generate_contains_signal_content
    Dir.mktmpdir do |build_dir|
      @generator.generate(build_dir)

      content = File.read("#{build_dir}/runtime.js")
      signal_rt = File.read(@generator.resolve_path("src/js/runtime/signal.js", ["src/js/runtime/signal.js"]))

      assert_includes content, signal_rt[0..100]
    end
  end

  def test_generate_contains_mochi_component_content
    Dir.mktmpdir do |build_dir|
      @generator.generate(build_dir)

      content = File.read("#{build_dir}/runtime.js")
      mochi_comp = File.read(@generator.resolve_path("src/js/runtime/mochi_component.js", ["src/js/runtime/mochi_component.js"]))

      assert_includes content, mochi_comp[0..100]
    end
  end
end
