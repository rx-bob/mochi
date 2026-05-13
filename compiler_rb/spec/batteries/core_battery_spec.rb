# typed: false
require_relative "../test_helper"
require_relative "../../src/batteries/core_battery"

class CoreBatteryTest < Minitest::Test
  def test_generate_creates_lib_dir_and_mochi_rb
    Dir.mktmpdir do |dir|
      CoreBattery.generate(dir)

      assert File.exist?("#{dir}/lib/mochi.rb"), "Expected lib/mochi.rb to be created"
    end
  end

  def test_generate_core_utils_contains_require_statements
    output = CoreBattery.generate_core_utils

    assert_includes output, "require 'json'"
    assert_includes output, 'require "await"'
  end

  def test_generate_core_utils_contains_all_fragments
    output = CoreBattery.generate_core_utils

    # mochi fragment
    assert_includes output, "class Mochi"
    # app_router fragment
    assert_includes output, "class AppRouter"
    # browser_id fragment
    assert_includes output, "class BrowserIdentifier"
    # logger fragment
    assert_includes output, "class Log"
    # charts fragments
    assert_includes output, "class Charts"
    assert_includes output, "class ChartConfig"
    assert_includes output, "class ChartSeries"
    assert_includes output, "class ChartConfigBuilder"
    assert_includes output, "class ChartSeriesBuilder"
    # fetcher fragments
    assert_includes output, "class HttpResponse"
    assert_includes output, "class FetchConfig"
    assert_includes output, "class FetchConfigBuilder"
    assert_includes output, "class Fetcher"
  end

  def test_generate_writes_combined_output_to_file
    Dir.mktmpdir do |dir|
      CoreBattery.generate(dir)
      content = File.read("#{dir}/lib/mochi.rb")

      assert_includes content, "class Mochi"
      assert_includes content, "class AppRouter"
      assert_includes content, "class Charts"
      assert_includes content, "class Fetcher"
    end
  end
end
