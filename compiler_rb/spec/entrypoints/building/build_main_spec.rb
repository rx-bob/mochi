# typed: false
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../src/entrypoints/build_main"
require_relative "../../../src/entrypoints/building/builder_man"

describe BuildMain do
  before do
    @tmpdir = Dir.mktmpdir("build_main_test")
    @input_dir = File.join(@tmpdir, "input")
    @output_dir = File.join(@tmpdir, "output")
    FileUtils.mkdir_p(@input_dir)
    FileUtils.mkdir_p(@output_dir)

    # Create a minimal input structure
    FileUtils.mkdir_p(File.join(@input_dir, "lib"))
    File.write(File.join(@input_dir, "lib", "MyComp.rb"), <<~RUBY)
      class MyComp
        @tag_name = "my-comp"

        def css
          "div { color: red; }"
        end

        def html
          "<div>hello {name}</div>"
        end
      end
    RUBY
  end

  after do
    FileUtils.rm_rf(@tmpdir)
  end

  it "initializes without args" do
    build_main = BuildMain.new
    assert_instance_of BuildMain, build_main
  end

  it "remove_file handles missing file" do
    build_main = BuildMain.new
    out = capture_io do
      build_main.remove_file("/tmp/nonexistent_file_12345.txt")
    end
    assert_includes out[0], "Unable to remove file"
  end

  it "remove_directory guards short paths" do
    build_main = BuildMain.new
    # short path (<= 5 chars) should not be removed
    build_main.remove_directory("/tmp")
    assert Dir.exist?("/tmp")
  end

  it "remove_directory removes valid path" do
    build_main = BuildMain.new
    test_dir = File.join(@tmpdir, "remove_me")
    FileUtils.mkdir_p(test_dir)
    build_main.remove_directory(test_dir)
    refute Dir.exist?(test_dir)
  end

  it "setup creates builtin files" do
    build_main = BuildMain.new
    builder_man = BuilderMan.new(@input_dir)

    build_main.setup(builder_man)

    # pre_tp should exist
    assert Dir.exist?(builder_man.pre_tp_dir)
    # built-in components should have been written
    assert File.exist?("#{builder_man.pre_tp_dir}/lib/mochi_router.rb")
    # src should exist after copy
    assert Dir.exist?(builder_man.ruby_src_dir)
    # batteries should have generated files
    assert File.exist?("#{builder_man.ruby_src_dir}/lib/mochi.rb")
  end

  it "build aborts when input or output empty" do
    build_main = BuildMain.new
    out = capture_io do
      assert_raises(SystemExit) do
        build_main.build("", "/tmp/out", nil, false, false, false)
      end
    end
    assert_includes out[0], "Input & output directory need to be specified"
  end
end
