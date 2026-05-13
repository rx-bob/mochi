# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class FragmentLoader
  extend T::Sig

  FRAGMENTS = T.let({
    "mochi_rb" => "fragments/batteries/mochi.rb",
    "app_router_rb" => "fragments/batteries/app_router.rb",
    "browser_id_rb" => "fragments/batteries/browser_id.rb",
    "logger_rb" => "fragments/batteries/logger.rb",
    # charts
    "charts_rb" => "fragments/batteries/charts/charts.rb",
    "chart_series_rb" => "fragments/batteries/charts/chart_series.rb",
    "chart_config_rb" => "fragments/batteries/charts/chart_config.rb",
    "chart_config_builder_rb" => "fragments/batteries/charts/chart_config_builder.rb",
    "chart_series_builder_rb" => "fragments/batteries/charts/chart_series_builder.rb",
    # fetcher
    "http_response_rb" => "fragments/batteries/fetcher/http_response.rb",
    "fetch_config_builder_rb" => "fragments/batteries/fetcher/fetch_config_builder.rb",
    "fetch_config_rb" => "fragments/batteries/fetcher/fetch_config.rb",
    "fetcher_rb" => "fragments/batteries/fetcher/fetcher.rb",
    # builtins
    "feather_icon_rb" => "fragments/builtins/feather_icon.rb",
    "route_rb" => "fragments/builtins/router/route.rb",
    "mochi_router_rb" => "fragments/builtins/router/mochi_router.rb",
    "my_counter_rb" => "fragments/builtins/my_counter.rb",
  }.freeze, T::Hash[String, String])

  sig { params(name: String).returns(String) }
  def self.load(name)
    path = resolve_path(T.must(FRAGMENTS[name]))
    File.read(path)
  end

  sig { returns(T::Array[String]) }
  def self.fragment_names
    FRAGMENTS.keys
  end

  sig { params(path: String).returns(String) }
  def self.resolve_path(path)
    candidates = [
      File.join(Dir.pwd, path),
      File.join(Dir.pwd, "..", path),
      File.join(Dir.pwd, "../..", path),
      File.expand_path(File.join("../../../", path), __dir__),
      File.expand_path(File.join("../../../../", path), __dir__),
    ]

    result = candidates.find { |candidate| File.exist?(candidate) }
    return result if result

    raise "Fragment not found: #{path} (tried: #{candidates.join(", ")})"
  end
end
