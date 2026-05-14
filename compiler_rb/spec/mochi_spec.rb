# typed: false
# frozen_string_literal: true

require_relative "test_helper"
require_relative "../src/mochi"

describe Mochi::CLI do
  before do
    @cli = Mochi::CLI.new
  end

  it "parses help flag" do
    out = capture_io do
      assert_raises(SystemExit) do
        @cli.run(["-h"])
      end
    end
    assert_includes out[0], "Usage:"
  end

  it "parses input and output flags" do
    @cli.parse(["-i", "./src", "-o", "./build"])
    # Cannot directly test fields since they are instance variables
    # but we can verify parsing doesn't error
    assert_instance_of OptionParser, @cli.parser
  end

  it "parses minimize flag" do
    @cli.parse(["--minimize"])
    # Just verify no exceptions
    assert_instance_of OptionParser, @cli.parser
  end

  it "handles unknown option" do
    assert_raises(SystemExit) do
      @cli.run(["--bogus"])
    end
  end

  it "handles missing argument" do
    assert_raises(SystemExit) do
      @cli.run(["-i"])
    end
  end

  it "exits on empty input/output in build mode" do
    out = capture_io do
      assert_raises(SystemExit) do
        @cli.run([])
      end
    end
    assert_includes out[0], "Input & output directory need to be specified"
  end

  it "exits on dev server without config" do
    out = capture_io do
      assert_raises(SystemExit) do
        @cli.run(["--dev"])
      end
    end
    assert_includes out[0], "No arguments provided"
  end

  it "has module-level helpers" do
    assert_equal "foo.element.getAttribute(bar)", Mochi.get_attr("foo", "bar")
    assert_equal ["a", "b"], Mochi.js_to_cr_array('["a","b"]')
    assert Mochi.generate_build_id.is_a?(String)
    refute Mochi.generate_build_id.empty?
    assert_equal 0, Mochi.find_second_last_index("abcabc", "abc")
    assert_equal(-1, Mochi.find_second_last_index("abc", "xyz"))

    out = capture_io { Mochi.print_separator }
    assert_equal 84, out[0].chomp.size

    out = capture_io { Mochi.print_cmp_start_separator("Foo", 1) }
    assert_includes out[0], "START"
    assert_includes out[0], "Foo"

    out = capture_io { Mochi.print_cmp_end_seperator("Foo", 1) }
    assert_includes out[0], "END"
    assert_includes out[0], "Foo"
  end
end
