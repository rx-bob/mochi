# typed: false
require_relative "../test_helper"
require_relative "../../src/ruby/ruby_rewriter"
require_relative "../../src/data_models/mochi_component"
require_relative "../../src/data_models/web_component"

class RubyRewriterTest < Minitest::Test
  def setup
    @rewriter = RubyRewriter.new
  end

  # --- rewrite ---

  def test_rewrite_returns_empty_string
    assert_equal "", @rewriter.rewrite
  end

  # --- extract_lib_path ---

  def test_extract_lib_path_returns_path_from_lib
    assert_equal "lib/foo/bar.rb", @rewriter.extract_lib_path("/some/path/lib/foo/bar.rb")
  end

  def test_extract_lib_path_returns_nil_when_no_lib
    assert_nil @rewriter.extract_lib_path("/some/path/foo/bar.rb")
  end

  def test_extract_lib_path_returns_full_path_starting_with_lib
    assert_equal "lib/bar.rb", @rewriter.extract_lib_path("lib/bar.rb")
  end

  # --- format_require_path ---

  def test_format_require_path_strips_lib_prefix
    assert_equal "foo/bar", @rewriter.format_require_path("lib/foo/bar.rb")
  end

  def test_format_require_path_strips_rb_suffix
    assert_equal "foo/bar", @rewriter.format_require_path("foo/bar.rb")
  end

  def test_format_require_path_strips_both
    assert_equal "foo/bar", @rewriter.format_require_path("lib/foo/bar.rb")
  end

  def test_format_require_path_leaves_other_paths_unchanged
    assert_equal "foo/bar/baz", @rewriter.format_require_path("foo/bar/baz")
  end

  # --- gen_mochi_ruby_root ---

  def test_gen_mochi_ruby_root_with_no_components
    result = @rewriter.gen_mochi_ruby_root([])

    assert_includes result, "require 'opal'"
    assert_includes result, "require 'native'"
    assert_includes result, "require 'promise'"
    assert_includes result, "require 'browser/setup/full'"
    assert_includes result, "require 'mochi'"
    assert_includes result, "class Root"
    assert_includes result, "end"
    assert_includes result, "Mochi.new"
  end

  def test_gen_mochi_ruby_root_with_components
    wc = WebComponent.new(name: "TestComp", js_code: "class TestComp {}")
    comp = MochiComponent.new(
      absolute_path: "/project/lib/counter.rb",
      name: "Counter",
      imports: [],
      ruby_code: "class Counter; end",
      web_component: wc,
      html: "<div></div>",
      css: ".foo {}"
    )

    result = @rewriter.gen_mochi_ruby_root([comp])

    assert_includes result, 'require "counter"'
    assert_includes result, "Counter.new"
  end

  def test_gen_mochi_ruby_root_ignores_components_without_lib_path
    wc = WebComponent.new(name: "TestComp", js_code: "class TestComp {}")
    comp = MochiComponent.new(
      absolute_path: "/project/src/counter.rb",
      name: "Counter",
      imports: [],
      ruby_code: "class Counter; end",
      web_component: wc,
      html: "<div></div>",
      css: ".foo {}"
    )

    result = @rewriter.gen_mochi_ruby_root([comp])

    refute_includes result, 'require "counter"'
  end

  def test_gen_mochi_ruby_root_multiple_components
    wc = WebComponent.new(name: "A", js_code: "")
    comp_a = MochiComponent.new(
      absolute_path: "/project/lib/a.rb",
      name: "A",
      imports: [],
      ruby_code: "",
      web_component: wc,
      html: "",
      css: ""
    )
    comp_b = MochiComponent.new(
      absolute_path: "/project/lib/b.rb",
      name: "B",
      imports: [],
      ruby_code: "",
      web_component: wc,
      html: "",
      css: ""
    )

    result = @rewriter.gen_mochi_ruby_root([comp_a, comp_b])

    assert_includes result, "A.new"
    assert_includes result, "B.new"
    assert_includes result, 'require "a"'
    assert_includes result, 'require "b"'
  end

  # --- gen_builtin_component_feather_icon ---

  def test_gen_builtin_component_feather_icon_returns_feather_icon_class
    result = @rewriter.gen_builtin_component_feather_icon
    assert_includes result, "class FeatherIcon"
  end

  # --- gen_builtin_mochi_router ---

  def test_gen_builtin_mochi_router_returns_router_class
    result = @rewriter.gen_builtin_mochi_router
    assert_includes result, "class MochiRouter"
  end

  # --- gen_builtin_route_component ---

  def test_gen_builtin_route_component_returns_route_class
    result = @rewriter.gen_builtin_route_component
    assert_includes result, "class Route"
  end

  # --- comment_out_sorbet_signatures ---

  def test_comment_out_sorbet_signatures_comments_sig_lines
    input = "foo\n  sig { params(x: Integer).returns(String) }\nbar"
    expected = "foo\n#  sig { params(x: Integer).returns(String) }\nbar"
    assert_equal expected, @rewriter.comment_out_sorbet_signatures(input)
  end

  def test_comment_out_sorbet_signatures_leaves_other_lines_unchanged
    input = "class Foo\n  def bar\n  end\nend"
    assert_equal input, @rewriter.comment_out_sorbet_signatures(input)
  end

  def test_comment_out_sorbet_signatures_handles_multiple_sigs
    input = "sig { void }\nfoo\nsig { returns(Integer) }\nbar"
    expected = "#sig { void }\nfoo\n#sig { returns(Integer) }\nbar"
    assert_equal expected, @rewriter.comment_out_sorbet_signatures(input)
  end

  def test_comment_out_sorbet_signatures_handles_sig_with_leading_whitespace
    input = "  sig { void }\n  def foo; end"
    expected = "#  sig { void }\n  def foo; end"
    assert_equal expected, @rewriter.comment_out_sorbet_signatures(input)
  end

  # --- comment_out_all_sorbet_signatures_in_dir ---

  def test_comment_out_all_sorbet_signatures_in_dir_processes_files
    Dir.mktmpdir do |dir|
      File.write("#{dir}/test.rb", "sig { void }\nclass Foo; end")

      @rewriter.comment_out_all_sorbet_signatures_in_dir(dir)

      content = File.read("#{dir}/test.rb")
      assert_includes content, "#sig { void }"
      assert_includes content, "class Foo; end"
    end
  end

  def test_comment_out_all_sorbet_signatures_in_dir_skips_non_directory
    @rewriter.comment_out_all_sorbet_signatures_in_dir("/nonexistent/path")
    # should not raise
  end

  def test_comment_out_all_sorbet_signatures_in_dir_recurses_subdirectories
    Dir.mktmpdir do |dir|
      sub = File.join(dir, "sub")
      FileUtils.mkdir_p(sub)
      File.write("#{sub}/test.rb", "sig { void }\nclass Bar; end")

      @rewriter.comment_out_all_sorbet_signatures_in_dir(dir)

      content = File.read("#{sub}/test.rb")
      assert_includes content, "#sig { void }"
    end
  end
end
