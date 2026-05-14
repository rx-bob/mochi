# typed: false
require_relative "../../test_helper"
require_relative "../../../src/entrypoints/building/builder_man"
require "fileutils"
require "tmpdir"

class BuilderManTest < Minitest::Test
  def setup
    @original_pwd = Dir.pwd
    @tmpdir = Dir.mktmpdir("builderman_test")
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@original_pwd)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_constructor_creates_build_dir
    bm = BuilderMan.new("/tmp/fake_input")
    assert Dir.exist?("#{@tmpdir}/build"), "build dir should be created"
  end

  def test_build_id_is_unique
    bm1 = BuilderMan.new("/tmp/fake_input")
    bm2 = BuilderMan.new("/tmp/fake_input")
    refute_equal bm1.build_id, bm2.build_id, "build_id should be unique"
  end

  def test_constructor_preserves_runtime_js
    FileUtils.mkdir_p("build")
    File.write("build/runtime.js", "// runtime")
    File.write("build/old_bundle.js", "// old")

    bm = BuilderMan.new("/tmp/fake_input")

    assert File.exist?("build/runtime.js"), "runtime.js should be preserved"
    refute File.exist?("build/old_bundle.js"), "old bundle should be removed"
  end

  def test_ruby_src_dir
    bm = BuilderMan.new("/tmp/fake_input")
    assert_includes bm.ruby_src_dir, "/build/src"
  end

  def test_pre_tp_dir
    bm = BuilderMan.new("/tmp/fake_input")
    assert_includes bm.pre_tp_dir, "/build/pre_tp"
  end

  def test_copy_ruby_code_to_pre_tp
    input_dir = File.join(@tmpdir, "input")
    FileUtils.mkdir_p(input_dir)
    File.write("#{input_dir}/foo.rb", "class Foo; end")
    File.write("#{input_dir}/bar.rb", "class Bar; end")

    bm = BuilderMan.new(input_dir)
    bm.copy_ruby_code_to_pre_tp

    assert File.exist?("#{@tmpdir}/build/pre_tp/foo.rb")
    assert File.exist?("#{@tmpdir}/build/pre_tp/bar.rb")
  end

  def test_copy_ruby_code_base
    input_dir = File.join(@tmpdir, "input")
    FileUtils.mkdir_p(input_dir)
    File.write("#{input_dir}/foo.rb", "class Foo; end")

    bm = BuilderMan.new(input_dir)
    bm.copy_ruby_code_to_pre_tp
    bm.copy_ruby_code_base

    assert File.exist?("#{@tmpdir}/build/src/foo.rb")
  end

  def test_nothing_to_delete_message
    FileUtils.mkdir_p("build")

    output = capture_io { BuilderMan.new("/tmp/fake_input") }[0]
    # Only "Nothing to delete." when only runtime.js exists (or when empty)
    # In this case build dir is newly created and empty after cleanup,
    # but the logic is: if entries_to_delete is empty, print message
    build_dir = "#{@tmpdir}/build"
    # Since the dir might be empty, paths_to_delete is empty, so we should see the message
  end
end
