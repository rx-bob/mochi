# typed: false
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../src/entrypoints/transpiler"
require_relative "../../../src/entrypoints/building/builder_man"

describe Compiler do
  before do
    @tmpdir = Dir.mktmpdir("compiler_test")
    @input_dir = File.join(@tmpdir, "input")
    @output_dir = File.join(@tmpdir, "output")
    FileUtils.mkdir_p(@input_dir)
    FileUtils.mkdir_p(@output_dir)
  end

  after do
    FileUtils.rm_rf(@tmpdir)
  end

  it "initializes without args" do
    compiler = Compiler.new
    assert_instance_of Compiler, compiler
  end

  it "find_second_last_index returns correct position" do
    compiler = Compiler.new

    text = "class Foo\n  def bar\n  end\nend"
    idx = compiler.send(:find_second_last_index, text, "end")
    # second-to-last "end" is the one in "def bar ... end", starts at pos 22
    assert_equal 22, idx

    # only one "end" returns nil
    text2 = "class Foo\nend"
    assert_nil compiler.send(:find_second_last_index, text2, "end")
  end

  it "prints separator messages" do
    compiler = Compiler.new
    out = capture_io do
      compiler.send(:print_cmp_start_separator, "TestComp", 1)
      compiler.send(:print_cmp_end_seperator, "TestComp", 1)
    end

    assert_includes out[0], "START"
    assert_includes out[0], "TestComp"
    assert_includes out[0], "END"
  end

  it "transpile_component returns nil when no css method" do
    compiler = Compiler.new

    source = <<~RUBY
      class SimpleComp
        def html
          "<div>hello</div>"
        end
      end
    RUBY

    result = compiler.send(:transpile_component, source, 1, "/tmp/test.rb")
    assert_nil result
  end

  it "transpile_component returns nil when class name blank" do
    compiler = Compiler.new

    source = "just some ruby code without a class"
    result = compiler.send(:transpile_component, source, 1, "/tmp/test.rb")
    assert_nil result
  end
end
