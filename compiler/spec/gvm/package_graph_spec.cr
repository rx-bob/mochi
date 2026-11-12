require "spec"
require "file_utils"
require "../../src/gvm/package_graph"

private def dependency_component(
  root : String,
  tag : String,
  class_name : String,
  source : String,
  html : String = "<p>#{tag}</p>",
) : MochiComponent
  manifest = ComponentManifest.new(
    tag,
    class_name,
    "#{tag}.chi",
    html,
    "",
    [] of BindingDescriptor,
    [] of EventDescriptor
  )
  manifest.source_file = "lib/#{tag}.rb"
  manifest.source_line = 1
  component = MochiComponent.new(
    File.join(root, "lib", "#{tag}.rb"),
    class_name,
    [] of String,
    source,
    manifest,
    html,
    "",
    1,
    "lib/#{tag}.rb",
    1
  )
  component.original_source = source
  component
end

private def dependency_prelude(root : String, path : String, source : String) : PreludeSource
  PreludeSource.new(
    File.join(root, path),
    path,
    source
  )
end

private def dependency_helper(root : String, key : String, path : String, source : String) : HelperUnit
  HelperUnit.new(
    key,
    source,
    path,
    File.join(root, path)
  )
end

private def dependency_graph(
  root : String,
  components : Array(MochiComponent),
  preludes : Array(PreludeSource) = [] of PreludeSource,
  helpers : Array(HelperUnit) = [] of HelperUnit,
) : MochiPackaging::PackageGraph
  MochiPackaging::PackageGraph.build(components, preludes, helpers, [root], root)
end

describe MochiPackaging::PackageGraph do
  it "keeps two isolated components independent of each other" do
    root = File.join(Dir.tempdir, "mochi_package_isolated_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      first = dependency_component(root, "isolated-first", "IsolatedFirst", <<-RUBY)
class IsolatedFirst
end
RUBY
      second = dependency_component(root, "isolated-second", "IsolatedSecond", <<-RUBY)
class IsolatedSecond
end
RUBY

      graph = dependency_graph(root, [first, second])
      graph.packages.size.should eq(2)
      graph.package("component:isolated-first").not_nil!.dependencies.should eq([] of String)
      graph.package("component:isolated-second").not_nil!.dependencies.should eq([] of String)
      graph.ruby_order.should eq([] of MochiPackaging::PackageNode)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "shares one helper package between every component that references it" do
    root = File.join(Dir.tempdir, "mochi_package_shared_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      helper = dependency_helper(root, "mochi-helpers-shared.chi", "lib/shared.rb", <<-RUBY)
class SharedHelper
  def self.label
    "shared"
  end
end
RUBY
      first = dependency_component(root, "shared-first", "SharedFirst", <<-RUBY)
class SharedFirst
end
RUBY
      second = dependency_component(root, "shared-second", "SharedSecond", <<-RUBY)
class SharedSecond
end
RUBY
      first.manifest.helper_chi = helper.key
      second.manifest.helper_chi = helper.key

      graph = dependency_graph(root, [first, second], helpers: [helper])
      helper_packages = graph.packages.values.select { |node| node.kind == "ruby" }
      helper_packages.size.should eq(1)
      helper_packages.first.id.should eq("helper:lib/shared.rb")
      first.manifest.dependencies.should eq(["helper:lib/shared.rb"])
      second.manifest.dependencies.should eq(["helper:lib/shared.rb"])
      graph.order.index("helper:lib/shared.rb").not_nil!.should be < graph.order.index("component:shared-first").not_nil!
      graph.order.index("helper:lib/shared.rb").not_nil!.should be < graph.order.index("component:shared-second").not_nil!
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "fails a missing require with Ruby source context" do
    root = File.join(Dir.tempdir, "mochi_package_missing_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      source = <<-RUBY
require "missing_feature"

class MissingFeature
end
RUBY
      component = dependency_component(root, "missing-feature", "MissingFeature", source)

      error = expect_raises(Exception) do
        dependency_graph(root, [component])
      end
      message = error.message.to_s
      message.should contain("missing Ruby dependency 'missing_feature'")
      message.should contain("lib/missing-feature.rb:1")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "fails unsupported dynamic loading with Ruby source context" do
    root = File.join(Dir.tempdir, "mochi_package_dynamic_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      source = <<-RUBY
feature = "chart"
require feature

class DynamicFeature
end
RUBY
      component = dependency_component(root, "dynamic-feature", "DynamicFeature", source)

      error = expect_raises(TreeSitter::ImportError) do
        dependency_graph(root, [component])
      end
      error.message.to_s.should contain("unsupported dynamic Ruby require at lib/dynamic-feature.rb:2:1")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "fails a deterministic dependency cycle with every package in the chain" do
    root = File.join(Dir.tempdir, "mochi_package_cycle_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      first = dependency_prelude(root, "lib/cycle_a.rb", <<-RUBY)
require_relative "cycle_b"

class CycleA
end
RUBY
      second = dependency_prelude(root, "lib/cycle_b.rb", <<-RUBY)
require_relative "cycle_a"

class CycleB
end
RUBY
      component = dependency_component(root, "cycle-user", "CycleUser", <<-RUBY)
require_relative "cycle_a"

class CycleUser
end
RUBY

      error = expect_raises(Exception) do
        dependency_graph(root, [component], [first, second])
      end
      message = error.message.to_s
      message.should contain("dependency cycle:")
      message.should contain("ruby:lib/cycle_a.rb")
      message.should contain("ruby:lib/cycle_b.rb")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "connects template constant references to the package that owns them" do
    root = File.join(Dir.tempdir, "mochi_package_template_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      icons = dependency_prelude(root, "lib/icons.rb", <<-RUBY)
class MochiIcons
  def self.icon(name)
    ""
  end
end
RUBY
      component = dependency_component(
        root,
        "icon-user",
        "IconUser",
        "class IconUser\nend\n",
        %Q{<span>{MochiIcons.icon("home")}</span>}
      )

      graph = dependency_graph(root, [component], [icons])
      component.manifest.dependencies.should eq(["ruby:lib/icons.rb"])
      graph.order.index("ruby:lib/icons.rb").not_nil!.should be < graph.order.index("component:icon-user").not_nil!
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects duplicate constant ownership inside the reachable graph" do
    root = File.join(Dir.tempdir, "mochi_package_duplicate_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      first = dependency_prelude(root, "lib/duplicate_a.rb", <<-RUBY)
class SharedHelper
end
RUBY
      second = dependency_prelude(root, "lib/duplicate_b.rb", <<-RUBY)
class SharedHelper
end
RUBY
      component = dependency_component(root, "duplicate-user", "DuplicateUser", <<-RUBY)
class DuplicateUser
  def helper
    SharedHelper
  end
end
RUBY

      error = expect_raises(Exception) do
        dependency_graph(root, [component], [first, second])
      end
      error.message.to_s.should contain("duplicate Ruby constant 'SharedHelper'")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "activates formatting only for the components whose closure exports MochiFormat" do
    root = File.join(Dir.tempdir, "mochi_package_capability_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      format = dependency_prelude(root, "lib/format.rb", <<-RUBY)
class MochiFormat
  def self.decimal(value, locale)
    value.to_s
  end
end
RUBY
      plain = dependency_component(root, "plain-panel", "PlainPanel", "class PlainPanel\nend\n")
      formatted = dependency_component(root, "format-panel", "FormatPanel", <<-RUBY)
class FormatPanel
end
RUBY
      formatted.manifest.helper_chi = "mochi-helpers-format.chi"
      helper = dependency_helper(root, "mochi-helpers-format.chi", "lib/format_wrapper.rb", <<-RUBY)
class FormatWrapper
  def self.show
    MochiFormat.decimal(1, "en-US")
  end
end
RUBY

      graph = dependency_graph(root, [plain, formatted], [format], [helper])
      graph.has_capability?("formatting").should be_true
      graph.capabilities["formatting"].host.should eq("mochi-format.js")
      graph.capabilities["formatting"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"format", "sync"}])
      plain.manifest.capabilities.should eq([] of String)
      plain.manifest.formatting.should be_false
      formatted.manifest.capabilities.should eq(["formatting"])
      formatted.manifest.formatting.should be_true
      graph.capability_package_ids.should eq(Set{"ruby:lib/format.rb"})
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rebuilds identical package identities, dependencies, and order across checkout paths" do
    root_one = File.join(Dir.tempdir, "mochi_package_reproducible_one_#{Random.rand(1_000_000)}")
    root_two = File.join(Dir.tempdir, "mochi_package_reproducible_two_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root_one, "lib"))
    Dir.mkdir_p(File.join(root_two, "lib"))
    begin
      helper_one = dependency_helper(root_one, "mochi-helpers-stable.chi", "lib/stable.rb", <<-RUBY)
class StableHelper
end
RUBY
      helper_two = dependency_helper(root_two, "mochi-helpers-stable.chi", "lib/stable.rb", <<-RUBY)
class StableHelper
end
RUBY
      first_one = dependency_component(root_one, "stable-one", "StableOne", "class StableOne\nend\n")
      second_one = dependency_component(root_one, "stable-two", "StableTwo", "class StableTwo\nend\n")
      first_two = dependency_component(root_two, "stable-one", "StableOne", "class StableOne\nend\n")
      second_two = dependency_component(root_two, "stable-two", "StableTwo", "class StableTwo\nend\n")
      first_one.manifest.helper_chi = helper_one.key
      second_one.manifest.helper_chi = helper_one.key
      first_two.manifest.helper_chi = helper_two.key
      second_two.manifest.helper_chi = helper_two.key

      one = dependency_graph(root_one, [first_one, second_one], helpers: [helper_one])
      two = dependency_graph(root_two, [first_two, second_two], helpers: [helper_two])
      one.order.should eq(two.order)
      one.packages.keys.sort.should eq(two.packages.keys.sort)
      one.packages.each do |id, node|
        other = two.packages[id]
        node.file.should eq(other.file)
        node.dependencies.should eq(other.dependencies)
        node.exports.should eq(other.exports)
        node.resources.should eq(other.resources)
      end
    ensure
      FileUtils.rm_rf(root_one)
      FileUtils.rm_rf(root_two)
    end
  end
end
