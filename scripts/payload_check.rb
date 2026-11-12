#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "set"
require "stringio"
require "tmpdir"
require "zlib"

# Deterministic artifact acceptance for the GVM bundle. This is intentionally
# not a benchmark: it builds the checked-in payload fixtures, derives their
# resources from the generated manifests, and compares the actual file set and
# byte counts against references/payload_budgets.json.
module PayloadCheck
  ROOT = File.expand_path("..", __dir__)
  COMPILER = File.join(ROOT, "compiler", "mochi")
  FIXTURES = File.join(ROOT, "compiler", "spec", "fixtures", "payload")
  BUDGETS_PATH = File.join(ROOT, "references", "payload_budgets.json")

  class Failure < StandardError; end

  module_function

  def run
    fail_unless(File.executable?(COMPILER), "missing compiler binary #{COMPILER}; run task build")
    budgets = JSON.parse(File.read(BUDGETS_PATH))
    fail_unless(budgets["schema_version"] == 1, "unsupported payload budget schema")
    fail_unless(budgets["compression"] == {
      "format" => "gzip",
      "level" => 9,
      "mtime" => 1
    }, "payload budget compression inputs changed")

    Dir.mktmpdir("mochi-payload-check-") do |tmp|
      minimal_a = build_fixture("minimal", File.join(tmp, "a"))
      minimal_b = build_fixture("minimal", File.join(tmp, "b"))
      feature_a = build_fixture("feature", File.join(tmp, "a"))
      feature_b = build_fixture("feature", File.join(tmp, "b"))

      assert_deterministic("minimal", minimal_a, minimal_b)
      assert_deterministic("feature", feature_a, feature_b)
      assert_common_initial_artifacts(minimal_a, feature_a)
      assert_minimal_boundary(minimal_a)
      assert_feature_boundary(feature_a)
      assert_exclusion_rejects_unused(minimal_a)
      print_report(minimal_a, feature_a)
      assert_budgets(minimal_a, feature_a, budgets)
    end
    puts "payload checks: ok"
  rescue Failure => error
    warn "payload checks: FAILED: #{error.message}"
    exit 1
  end

  def fail_unless(condition, message)
    raise Failure, message unless condition
  end

  def build_fixture(name, parent)
    FileUtils.mkdir_p(parent)
    source = File.join(parent, name)
    FileUtils.cp_r(File.join(FIXTURES, name), source)
    output = File.join(parent, "#{name}-bundle")
    stdout, stderr, status = Open3.capture3(
      COMPILER, "-i", source, "-o", output,
      chdir: ROOT
    )
    unless status.success?
      raise Failure, "#{name} build failed\n#{stdout}\n#{stderr}"
    end
    Bundle.new(output)
  end

  class Bundle
    attr_reader :dir, :manifest

    def initialize(dir)
      @dir = File.expand_path(dir)
      @manifest = JSON.parse(File.read(path("mochi-manifest.json")))
    end

    def path(relative)
      File.join(@dir, relative)
    end

    def files
      @files ||= Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH)
        .select { |entry| File.file?(entry) }
        .map { |entry| entry.delete_prefix(@dir + File::SEPARATOR) }
        .sort
    end

    def digests
      @digests ||= files.to_h do |relative|
        [relative, Digest::SHA256.file(path(relative)).hexdigest]
      end
    end

    def core_files
      [
        manifest.fetch("wasm_file"),
        manifest.fetch("js_file"),
        manifest.fetch("loader_file")
      ]
    end

    def referenced_files
      referenced = Set.new(core_files)
      referenced << "mochi-manifest.json"
      referenced << "index.html"
      referenced << manifest["prelude"] if manifest["prelude"]
      manifest.fetch("components").each { |component| referenced << component.fetch("descriptor") }
      manifest.fetch("packages").each_value do |package|
        referenced << package.fetch("file")
        (package["resources"] || []).each do |resource_id|
          referenced << manifest.fetch("resources").fetch(resource_id).fetch("file")
        end
        (package["dependencies"] || []).each do |dependency|
          PayloadCheck.fail_unless(
            manifest["packages"].key?(dependency),
            "package #{package.fetch("file")} references missing dependency #{dependency}"
          )
        end
      end
      (manifest["resources"] || {}).each_value do |resource|
        referenced << resource.fetch("file")
      end
      (manifest["capabilities"] || {}).each_value do |capability|
        referenced << capability["host"] if capability["host"]
      end
      referenced << manifest["format_host"] if manifest["format_host"]
      referenced
    end

    def initial_files
      @initial_files ||= begin
        tags = initial_tags
        packages = initial_package_ids(tags)
        closure = dependency_closure(packages)
        initial = Set.new(core_files)
        initial << "mochi-manifest.json"
        initial << "index.html"
        initial << manifest["prelude"] if manifest["prelude"]

        manifest.fetch("components").each do |component|
          next unless tags.include?(component.fetch("tag_name"))
          initial << component.fetch("descriptor")
        end

        closure.each do |package_id|
          package = manifest.fetch("packages").fetch(package_id)
          initial << package.fetch("file")
          (package["resources"] || []).each do |resource_id|
            initial << manifest.fetch("resources").fetch(resource_id).fetch("file")
          end
        end

        (manifest["capabilities"] || {}).each_value do |capability|
          next if (capability["packages"] & closure.to_a).empty?
          initial << capability["host"] if capability["host"]
        end

        (manifest["resources"] || {}).each_value do |resource|
          initial << resource.fetch("file") if resource["initial"] == true
        end
        initial
      end
    end

    def later_files
      referenced_files - initial_files
    end

    def unexpected_files
      files.to_set - referenced_files
    end

    def missing_files
      referenced_files - files.to_set
    end

    def duplicate_files
      owners = Hash.new { |hash, key| hash[key] = [] }
      manifest.fetch("packages").each do |package_id, package|
        owners[package.fetch("file")] << package_id
      end
      (manifest["resources"] || {}).each do |resource_id, resource|
        owners[resource.fetch("file")] << "resource:#{resource_id}"
      end
      owners.select { |_file, names| names.length > 1 }
    end

    def initial_tags
      html = File.read(path("index.html"))
      manifest.fetch("components").map { |component| component.fetch("tag_name") }
        .select { |tag| html.match?(%r{<\s*#{Regexp.escape(tag)}(?:\s|>|/)}) }
        .sort
    end

    def initial_package_ids(tags)
      manifest.fetch("components").each_with_object([]) do |component, package_ids|
        package = component["package"]
        package_ids << package if package && tags.include?(component.fetch("tag_name"))
      end.sort
    end

    def dependency_closure(package_ids)
      closure = Set.new
      queue = package_ids.dup
      until queue.empty?
        package_id = queue.shift
        next if closure.include?(package_id)
        package = manifest.fetch("packages").fetch(package_id)
        closure << package_id
        (package["dependencies"] || []).each { |dependency| queue << dependency }
      end
      closure
    end

    def summary(relative_files)
      files = relative_files.to_a.sort
      {
        "raw" => files.sum { |relative| File.size(path(relative)) },
        "gzip" => files.sum { |relative| PayloadCheck.gzip_size(path(relative)) }
      }
    end
  end

  def assert_deterministic(name, left, right)
    fail_unless(
      left.digests == right.digests,
      "#{name} build is not deterministic:\n" \
        "left-only/changed: #{(left.digests.to_a - right.digests.to_a).inspect}\n" \
        "right-only/changed: #{(right.digests.to_a - left.digests.to_a).inspect}"
    )
  end

  def assert_common_initial_artifacts(minimal, feature)
    # The manifest legitimately grows by capability metadata. Every other
    # initial file must be byte-identical, including any prelude, styles, and
    # entry component descriptor or bytecode.
    ignored = Set["mochi-manifest.json"]
    minimal_initial = minimal.initial_files - ignored
    feature_initial = feature.initial_files - ignored
    fail_unless(
      minimal_initial == feature_initial,
      "optional formatting changed the initial file set: " \
        "minimal-only #{(minimal_initial - feature_initial).to_a.inspect}, " \
        "feature-only #{(feature_initial - minimal_initial).to_a.inspect}"
    )
    minimal_initial.each do |relative|
      fail_unless(
        minimal.digests.fetch(relative) == feature.digests.fetch(relative),
        "optional formatting changed initial artifact #{relative}"
      )
    end
  end

  def assert_minimal_boundary(bundle)
    fail_unless(bundle.unexpected_files.empty?,
      "unused files in minimal bundle: #{bundle.unexpected_files.to_a.inspect}")
    fail_unless(bundle.missing_files.empty?,
      "missing files in minimal bundle: #{bundle.missing_files.to_a.inspect}")
    fail_unless(bundle.later_files.empty?,
      "minimal bundle unexpectedly has later files: #{bundle.later_files.to_a.inspect}")
    fail_unless(bundle.manifest["capabilities"].nil?,
      "minimal bundle declares a host capability")
    fail_unless(bundle.manifest["format_host"].nil?,
      "minimal bundle declares a formatting adapter")
    fail_unless(!bundle.files.include?("mochi-format.js"),
      "minimal bundle includes mochi-format.js")
    fail_unless(bundle.duplicate_files.empty?,
      "duplicate package/resource files: #{bundle.duplicate_files.inspect}")
  end

  def assert_feature_boundary(bundle)
    fail_unless(bundle.unexpected_files.empty?,
      "unused files in feature bundle: #{bundle.unexpected_files.to_a.inspect}")
    fail_unless(bundle.missing_files.empty?,
      "missing files in feature bundle: #{bundle.missing_files.to_a.inspect}")
    expected_later = [
      "components/format-badge.chi",
      "components/format-badge.json",
      "mochi-format.js"
    ]
    ruby_features = bundle.later_files.grep(%r{\Acomponents/ruby-[0-9a-f]+\.chi\z})
    fail_unless(ruby_features.length == 1,
      "feature bundle should load exactly one Ruby capability package, got #{ruby_features.inspect}")
    actual_later = (bundle.later_files - ruby_features).to_a.sort
    fail_unless(actual_later == expected_later,
      "feature later-load set changed: expected #{expected_later.inspect}, got #{actual_later.inspect}")
    fail_unless(bundle.initial_files.intersect?(bundle.later_files) == false,
      "initial and later feature sets overlap")
    duplicate_files = bundle.duplicate_files
    fail_unless(duplicate_files.empty?,
      "duplicate package/resource files: #{duplicate_files.inspect}")
  end

  def assert_exclusion_rejects_unused(bundle)
    assert_unexpected_file(
      bundle,
      "mochi-format.js",
      File.read(File.join(ROOT, "runtime", "mochi-format.js")),
      "unused adapter"
    )
    assert_unexpected_file(
      bundle,
      "components/styles/orphan.css",
      ".orphan{color:red}\n",
      "unused stylesheet"
    )
  end

  def assert_unexpected_file(bundle, relative, content, label)
    Dir.mktmpdir("mochi-payload-negative-") do |tmp|
      FileUtils.cp_r(File.join(bundle.dir, "."), tmp)
      target = File.join(tmp, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content)
      unexpected = Bundle.new(tmp).unexpected_files
      fail_unless(unexpected.include?(relative),
        "#{label} exclusion check did not reject #{relative}")
    end
  end

  def assert_budgets(minimal, feature, budgets)
    actual = {
      "core" => feature.summary(feature.core_files),
      "minimal_initial" => minimal.summary(minimal.initial_files),
      "feature_initial" => feature.summary(feature.initial_files),
      "feature_later" => feature.summary(feature.later_files),
      "feature_total" => feature.summary(feature.files)
    }
    actual.each do |name, measured|
      baseline = budgets.fetch("baselines").fetch(name)
      gzip_tolerance = budgets.fetch("gzip_tolerance")
      gzip_ceiling = baseline.fetch("gzip") + [
        gzip_tolerance.fetch("minimum_bytes"),
        (baseline.fetch("gzip") * gzip_tolerance.fetch("ratio")).ceil
      ].max
      fail_unless(measured.fetch("raw") <= baseline.fetch("raw"),
        "#{name} raw bytes #{measured.fetch("raw")} exceed ceiling #{baseline.fetch("raw")}")
      fail_unless(measured.fetch("gzip") <= gzip_ceiling,
        "#{name} gzip bytes #{measured.fetch("gzip")} exceed ceiling #{gzip_ceiling}")
    end
  end

  def print_report(minimal, feature)
    puts "payload artifact baselines (raw / gzip)"
    print_set("core", feature, feature.core_files)
    print_set("minimal initial", minimal, minimal.initial_files)
    print_set("feature initial", feature, feature.initial_files)
    print_set("feature later", feature, feature.later_files)
    print_set("feature total", feature, feature.files)
    puts
    puts "initial files:"
    minimal.initial_files.sort.each { |relative| print_file(minimal, relative) }
    puts
    puts "later feature files:"
    feature.later_files.sort.each { |relative| print_file(feature, relative) }
  end

  def print_set(label, bundle, files)
    summary = bundle.summary(files)
    puts format("%-18s %8d / %8d  (%d files)", label, summary.fetch("raw"), summary.fetch("gzip"), files.length)
  end

  def print_file(bundle, relative)
    puts format("  %8d / %8d  %s",
      File.size(bundle.path(relative)),
      PayloadCheck.gzip_size(bundle.path(relative)),
      relative)
  end

  def gzip_size(path)
    output = StringIO.new
    writer = Zlib::GzipWriter.new(output, Zlib::BEST_COMPRESSION)
    writer.mtime = 1
    File.open(path, "rb") { |input| IO.copy_stream(input, writer) }
    writer.close
    output.string.bytesize
  end
end

PayloadCheck.run if $PROGRAM_NAME == __FILE__
