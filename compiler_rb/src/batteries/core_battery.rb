# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "fragment_loader"

require "fileutils"

class CoreBattery
  extend T::Sig

  sig { params(ruby_src_dir: String).void }
  def self.generate(ruby_src_dir)
    output_dir = "#{ruby_src_dir}/lib"
    FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

    File.write("#{output_dir}/mochi.rb", generate_core_utils)
  end

  sig { returns(String) }
  def self.generate_core_utils
    result = <<~RUBY
      # await: true
      require 'json'
      require "await"
    RUBY

    fragment_names = [
      "mochi_rb",
      "app_router_rb",
      "browser_id_rb",
      "logger_rb",
      # charts
      "charts_rb",
      "chart_series_rb",
      "chart_config_builder_rb",
      "chart_config_rb",
      "chart_series_builder_rb",
      # fetcher
      "http_response_rb",
      "fetch_config_builder_rb",
      "fetch_config_rb",
      "fetcher_rb",
    ]

    fragments = fragment_names.map { |name| FragmentLoader.load(name) }.join("\n")

    "#{result}\n#{fragments}"
  end
end
