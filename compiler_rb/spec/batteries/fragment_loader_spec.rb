# typed: false
require_relative "../test_helper"
require_relative "../../src/batteries/fragment_loader"

class FragmentLoaderTest < Minitest::Test
  def test_load_mochi_fragment
    content = FragmentLoader.load("mochi_rb")
    assert_match(/class Mochi/, content)
  end

  def test_load_app_router_fragment
    content = FragmentLoader.load("app_router_rb")
    assert_match(/class AppRouter/, content)
  end

  def test_load_browser_id_fragment
    content = FragmentLoader.load("browser_id_rb")
    assert_match(/class BrowserId/, content)
  end

  def test_load_logger_fragment
    content = FragmentLoader.load("logger_rb")
    assert_match(/class Log/, content)
  end

  def test_load_charts_fragment
    content = FragmentLoader.load("charts_rb")
    assert_match(/class Charts/, content)
  end

  def test_load_fetcher_fragment
    content = FragmentLoader.load("fetcher_rb")
    assert_match(/class Fetcher/, content)
  end

  def test_load_builtin_feather_icon_fragment
    content = FragmentLoader.load("feather_icon_rb")
    assert_match(/class FeatherIcon/, content)
  end

  def test_load_builtin_route_fragment
    content = FragmentLoader.load("route_rb")
    assert_match(/class Route/, content)
  end

  def test_load_builtin_mochi_router_fragment
    content = FragmentLoader.load("mochi_router_rb")
    assert_match(/class MochiRouter/, content)
  end

  def test_load_builtin_my_counter_fragment
    content = FragmentLoader.load("my_counter_rb")
    assert_match(/class MyCounter/, content)
  end

  def test_load_all_fragments_are_present
    names = FragmentLoader.fragment_names
    refute_empty names
    assert_includes names, "mochi_rb"
    assert_includes names, "app_router_rb"
    assert_includes names, "charts_rb"
    assert_includes names, "fetcher_rb"
    assert_includes names, "feather_icon_rb"
    assert_includes names, "mochi_router_rb"
    assert_includes names, "my_counter_rb"
  end

  def test_load_raises_for_unknown_fragment
    assert_raises { FragmentLoader.load("unknown_rb") }
  end

  def test_resolve_path_finds_existing_file
    path = FragmentLoader.resolve_path("fragments/batteries/mochi.rb")
    assert File.exist?(path)
  end

  def test_resolve_path_raises_for_missing_file
    assert_raises { FragmentLoader.resolve_path("fragments/nonexistent/foo.rb") }
  end

  def test_load_returns_string_content
    content = FragmentLoader.load("mochi_rb")
    assert_instance_of String, content
    assert content.length > 0
  end
end
