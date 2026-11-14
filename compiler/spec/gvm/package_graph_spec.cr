require "spec"
require "file_utils"
require "../../src/gvm/package_graph"
require "../../src/webcomponents/component_generator"
require "../../src/ruby/each_method_generator"

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
  it "loads Time and its clock only for constant, require, and helper consumers" do
    root = File.join(Dir.tempdir, "mochi_package_time_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      time = dependency_prelude(root, "lib/mochi_builtin_time.rb", "class Time\nend\n")
      plain = dependency_component(root, "plain-time", "PlainTime", "class PlainTime\nend\n")
      required = dependency_component(root, "required-time", "RequiredTime", "require 'time'\nclass RequiredTime\nend\n")
      direct = dependency_component(root, "direct-time", "DirectTime", "class DirectTime\n def value\n Time.at(0)\n end\nend\n")
      helper = dependency_helper(root, "time-helper.chi", "lib/time_helper.rb", "class TimeHelper\n def self.value\n Time.now\n end\nend\n")
      indirect = dependency_component(root, "indirect-time", "IndirectTime", "class IndirectTime\n def value\n TimeHelper.value\n end\nend\n")
      indirect.manifest.helper_chi = helper.key
      graph = dependency_graph(root, [plain, required, direct, indirect], [time], [helper])
      id = "ruby:lib/mochi_builtin_time.rb"
      plain.manifest.dependencies.should eq([] of String)
      plain.manifest.capabilities.should eq([] of String)
      [required, direct].each { |component| component.manifest.dependencies.should contain(id) }
      [required, direct, indirect].each { |component| component.manifest.capabilities.should eq(["time"]) }
      graph.package("helper:lib/time_helper.rb").not_nil!.dependencies.should contain(id)
      graph.capabilities["time"].host.should eq("mochi-time.js")
      graph.capabilities["time"].operations.map { |operation| {operation.name, operation.mode} }.should eq([{"now", "sync"}])
      unrelated = dependency_graph(root, [plain], [time])
      unrelated.ruby_order.should eq([] of MochiPackaging::PackageNode)
      unrelated.has_capability?("time").should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads JSON only for requires, constant users, and reachable helpers" do
    root = File.join(Dir.tempdir, "mochi_package_json_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      json = dependency_prelude(root, "lib/mochi_builtin_json.rb", "module JSON\nend\n")
      plain = dependency_component(root, "plain-json", "PlainJSON", "class PlainJSON\nend\n")
      required = dependency_component(root, "required-json", "RequiredJSON", "require 'json'\nclass RequiredJSON\nend\n")
      direct = dependency_component(root, "direct-json", "DirectJSON", "class DirectJSON\n def value\n JSON.parse('null')\n end\nend\n")
      helper = dependency_helper(root, "json-helper.chi", "lib/json_helper.rb", "require 'json'\nclass JSONHelper\nend\n")
      indirect = dependency_component(root, "indirect-json", "IndirectJSON", "class IndirectJSON\n def value\n JSONHelper.new\n end\nend\n")
      indirect.manifest.helper_chi = helper.key
      graph = dependency_graph(root, [plain, required, direct, indirect], [json], [helper])
      id = "ruby:lib/mochi_builtin_json.rb"
      plain.manifest.dependencies.should eq([] of String)
      required.manifest.dependencies.should contain(id)
      direct.manifest.dependencies.should contain(id)
      graph.package("helper:lib/json_helper.rb").not_nil!.dependencies.should contain(id)
      indirect.manifest.dependencies.should contain("helper:lib/json_helper.rb")
      graph.capability_package_ids.should eq(Set(String).new)
      dependency_graph(root, [plain], [json]).ruby_order.should eq([] of MochiPackaging::PackageNode)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps local json files ahead of the builtin and diagnoses missing JSON" do
    root = File.join(Dir.tempdir, "mochi_package_json_local_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      consumer = dependency_component(root, "json-local", "JSONLocal", "require 'json'\nclass JSONLocal\nend\n")
      builtin = dependency_prelude(root, "lib/mochi_builtin_json.rb", "module JSON\nend\n")
      local = dependency_prelude(root, "lib/json.rb", "class LocalJSON\nend\n")
      dependency_graph(root, [consumer], [builtin, local])
      consumer.manifest.dependencies.should eq(["ruby:lib/json.rb"])
      expect_raises(Exception, /missing Ruby dependency 'json'/) do
        dependency_graph(root, [consumer])
      end
      relative = dependency_component(root, "json-relative", "JSONRelative", "require_relative 'json'\nclass JSONRelative\nend\n")
      expect_raises(Exception, /missing Ruby dependency 'json'/) do
        dependency_graph(root, [relative], [builtin])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

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

  it "records page component roots while retaining descriptors for dynamic components" do
    root = File.join(Dir.tempdir, "mochi_package_page_roots_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      File.write(File.join(root, "index.html"), "<entry-root></entry-root>")
      entry = dependency_component(root, "entry-root", "EntryRoot", "class EntryRoot\nend\n", "<root-child></root-child>")
      child = dependency_component(root, "root-child", "RootChild", "class RootChild\nend\n")
      unrelated = dependency_component(root, "unrelated-root", "UnrelatedRoot", "class UnrelatedRoot\nend\n")

      graph = dependency_graph(root, [entry, child, unrelated])

      graph.entry_packages.should eq(["component:entry-root"])
      graph.component_order.map { |component| component.manifest.tag_name }.to_set
        .should eq(Set{"entry-root", "root-child", "unrelated-root"})
      graph.package("component:unrelated-root").should_not be_nil
      graph.order.should contain("component:unrelated-root")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps conditional child components out of the eager dependency set" do
    root = File.join(Dir.tempdir, "mochi_package_lazy_children_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      chrome = dependency_component(root, "child-chrome", "ChildChrome", <<-RUBY)
class ChildChrome
end
RUBY
      screen = dependency_component(root, "child-screen", "ChildScreen", <<-RUBY)
class ChildScreen
end
RUBY
      host = dependency_component(root, "child-host", "ChildHost", <<-RUBY, "<child-chrome></child-chrome><!--if-anchor-0-->")
class ChildHost
end
RUBY
      host.manifest.bindings = [
        BindingDescriptor.new(
          0,
          [2],
          "cond",
          "__mochi_bind_0",
          branches: [
            ConditionalBranchDescriptor.new("<child-screen></child-screen>"),
          ],
        ),
      ]

      graph = dependency_graph(root, [host, chrome, screen])
      host.manifest.dependencies.should eq(["component:child-chrome"])
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

  it "loads the network host only for reachable Ruby packages that call Mochi.fetch" do
    root = File.join(Dir.tempdir, "mochi_package_network_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      plain = dependency_component(root, "plain-panel", "PlainPanel", "class PlainPanel\nend\n")
      fetched = dependency_component(root, "fetch-panel", "FetchPanel", <<-RUBY)
class FetchPanel
  def load_data
    Mochi.fetch("/api/items", :receive_items)
  end
end
RUBY

      graph = dependency_graph(root, [plain, fetched])
      graph.has_capability?("network").should be_true
      graph.capabilities["network"].host.should eq("mochi-fetch.js")
      graph.capabilities["network"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"fetch", "async"}, {"cancel", "sync"}])
      graph.capabilities["network"].limit_keys.sort_by(&.first).should eq([
        {"envelope_bytes", "host_fetch_envelope_bytes"},
        {"pending_requests", "host_network_pending_requests"},
        {"response_buffer_bytes", "host_network_buffer_bytes"},
        {"response_bytes", "host_network_response_bytes"},
      ])
      plain.manifest.capabilities.should eq([] of String)
      fetched.manifest.capabilities.should eq(["network"])
      graph.capability_package_ids.should eq(Set{"component:fetch-panel"})
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads layout only through reachable Ruby measurement dependencies" do
    root = File.join(Dir.tempdir, "mochi_package_layout_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      layout = dependency_prelude(root, "lib/mochi_builtin_layout.rb", "class MochiLayout\nend\n")
      plain = dependency_component(root, "plain-layout", "PlainLayout", "class PlainLayout\nend\n")
      helper = dependency_helper(root, "mochi-helpers-layout.chi", "lib/layout_helper.rb", <<-RUBY)
class LayoutHelper
  def self.watch
    MochiLayout.observe("viewport", "on_viewport")
  end
end
RUBY
      measured = dependency_component(root, "measured-layout", "MeasuredLayout", "class MeasuredLayout\n  def mounted\n    LayoutHelper.watch\n  end\nend\n")
      measured.manifest.helper_chi = helper.key
      graph = dependency_graph(root, [plain, measured], [layout], [helper])
      plain.manifest.capabilities.should eq([] of String)
      measured.manifest.capabilities.should eq(["layout"])
      graph.capabilities["layout"].host.should eq("mochi-layout.js")
      graph.capabilities["layout"].limit_keys.should eq([{"requests", "bindings"}])
      graph.capabilities["layout"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"measure", "async"}, {"observe", "async"}, {"cancel", "async"}])
      unused = dependency_graph(root, [plain], [layout], [] of HelperUnit)
      unused.has_capability?("layout").should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads shortcuts only through reachable Ruby shortcut dependencies" do
    root = File.join(Dir.tempdir, "mochi_package_shortcuts_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      shortcuts = dependency_prelude(root, "lib/mochi_builtin_shortcuts.rb", "class MochiShortcuts\nend\n")
      plain = dependency_component(root, "plain-shortcuts", "PlainShortcuts", "class PlainShortcuts\nend\n")
      helper = dependency_helper(root, "mochi-helpers-shortcuts.chi", "lib/shortcuts_helper.rb", <<-RUBY)
class ShortcutsHelper
  def self.watch
    MochiShortcuts.register("Escape", "on_escape")
  end
end
RUBY
      measured = dependency_component(root, "measured-shortcuts", "MeasuredShortcuts", "class MeasuredShortcuts\n  def mounted\n    ShortcutsHelper.watch\n  end\nend\n")
      measured.manifest.helper_chi = helper.key
      graph = dependency_graph(root, [plain, measured], [shortcuts], [helper])
      plain.manifest.capabilities.should eq([] of String)
      measured.manifest.capabilities.should eq(["shortcuts"])
      graph.capabilities["shortcuts"].host.should eq("mochi-shortcuts.js")
      graph.capabilities["shortcuts"].limit_keys.should eq([{"registrations", "bindings"}])
      graph.capabilities["shortcuts"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"register", "async"}, {"cancel", "async"}])
      unused = dependency_graph(root, [plain], [shortcuts], [] of HelperUnit)
      unused.has_capability?("shortcuts").should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads the pointer adapter only for components that reach MochiPointer" do
    root = File.join(Dir.tempdir, "mochi_package_pointer_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      pointer = dependency_prelude(root, "lib/mochi_builtin_pointer.rb", <<-RUBY)
class MochiPointer
  def self.capture(pointer_id, reference = nil)
    Mochi.pointer_capture(pointer_id, reference)
  end
end
RUBY
      plain = dependency_component(root, "plain-pointer", "PlainPointer", "class PlainPointer\nend\n")
      direct = dependency_component(root, "direct-pointer", "DirectPointer", <<-RUBY)
class DirectPointer
  def begin_drag(event)
    MochiPointer.capture(event[:pointer_id], :handle)
  end
end
RUBY
      helper = dependency_helper(root, "mochi-helpers-pointer.chi", "lib/pointer_helper.rb", <<-RUBY)
class PointerHelper
  def self.begin_drag(event)
    MochiPointer.capture(event[:pointer_id], :handle)
  end
end
RUBY
      indirect = dependency_component(root, "indirect-pointer", "IndirectPointer", <<-RUBY)
class IndirectPointer
  def begin_drag(event)
    PointerHelper.begin_drag(event)
  end
end
RUBY
      indirect.manifest.helper_chi = helper.key

      graph = dependency_graph(root, [plain, direct, indirect], [pointer], [helper])
      graph.has_capability?("pointer").should be_true
      graph.capabilities["pointer"].host.should eq("mochi-pointer.js")
      graph.capabilities["pointer"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"capture", "sync"}, {"release", "sync"}])
      graph.capability_package_ids.should contain("ruby:lib/mochi_builtin_pointer.rb")
      plain.manifest.capabilities.should eq([] of String)
      direct.manifest.capabilities.should eq(["pointer"])
      indirect.manifest.capabilities.should eq(["pointer"])
      indirect.manifest.dependencies.should contain("helper:lib/pointer_helper.rb")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads Array aggregation bytecode for direct and helper sends only" do
    root = File.join(Dir.tempdir, "mochi_package_aggregates_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      collections = dependency_prelude(root, "lib/mochi_builtin_collections.rb", <<-RUBY)
class Array
  def sum(initial = 0)
    initial
  end
end
RUBY
      plain = dependency_component(root, "plain-aggregate", "PlainAggregate", "class PlainAggregate\nend\n")
      direct = dependency_component(root, "direct-aggregate", "DirectAggregate", <<-RUBY)
class DirectAggregate
  def total(values)
    values.sum(5)
  end
end
RUBY
      helper = dependency_helper(root, "mochi-helpers-aggregate.chi", "lib/aggregate_helper.rb", <<-RUBY)
class AggregateHelper
  def self.lowest(rows)
    rows.min
  end
end
RUBY
      indirect = dependency_component(root, "indirect-aggregate", "IndirectAggregate", <<-RUBY)
class IndirectAggregate
  def lowest(rows)
    AggregateHelper.lowest(rows)
  end
end
RUBY
      indirect.manifest.helper_chi = helper.key

      graph = dependency_graph(root, [plain, direct, indirect], [collections], [helper])
      collection_id = "ruby:lib/mochi_builtin_collections.rb"
      direct.manifest.dependencies.should contain(collection_id)
      graph.package("helper:lib/aggregate_helper.rb").not_nil!.dependencies.should contain(collection_id)
      indirect.manifest.dependencies.should contain("helper:lib/aggregate_helper.rb")
      plain.manifest.dependencies.should_not contain(collection_id)
      plain.manifest.dependencies.should eq([] of String)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads the native drag adapter only for reachable MochiDrag users" do
    root = File.join(Dir.tempdir, "mochi_package_drag_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      drag = dependency_prelude(root, "lib/mochi_builtin_drag.rb", <<-RUBY)
class MochiDrag
  def self.set_data(value)
    Mochi.drag_set_data(value)
  end
end
RUBY
      plain = dependency_component(root, "plain-drag", "PlainDrag", "class PlainDrag\nend\n")
      direct = dependency_component(root, "direct-drag", "DirectDrag", <<-RUBY)
class DirectDrag
  def begin_drag(event)
    MochiDrag.set_data(false)
  end
end
RUBY

      graph = dependency_graph(root, [plain, direct], [drag])
      graph.has_capability?("drag").should be_true
      graph.capabilities["drag"].host.should eq("mochi-drag.js")
      graph.capabilities["drag"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([{"set_data", "sync"}, {"set_text", "sync"}, {"accept", "sync"}])
      graph.capabilities["drag"].limit_keys.should eq([{"payload_bytes", "host_drag_payload_bytes"}])
      graph.capability_package_ids.should eq(Set{"ruby:lib/mochi_builtin_drag.rb"})
      plain.manifest.capabilities.should eq([] of String)
      direct.manifest.capabilities.should eq(["drag"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "loads file handles independently from drag for reachable MochiFiles users" do
    root = File.join(Dir.tempdir, "mochi_package_files_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      files = dependency_prelude(root, "lib/mochi_builtin_files.rb", <<-RUBY)
class MochiFiles
  def self.release(handle)
    Mochi.file_release(handle)
  end
end
RUBY
      plain = dependency_component(root, "plain-files", "PlainFiles", "class PlainFiles\nend\n")
      direct = dependency_component(root, "direct-files", "DirectFiles", <<-RUBY)
class DirectFiles
  def release_file(handle)
    MochiFiles.release(handle)
  end
end
RUBY

      graph = dependency_graph(root, [plain, direct], [files])
      graph.has_capability?("files").should be_true
      graph.capabilities["files"].host.should eq("mochi-files.js")
      graph.capabilities["files"].operations.map { |operation| {operation.name, operation.mode} }
        .should eq([
          {"release", "sync"}, {"open", "sync"}, {"close", "sync"}, {"read_next", "async"},
          {"read", "async"}, {"read_text", "async"},
        ])
      graph.capabilities["files"].limit_keys.sort.should eq([
        {"handles", "host_file_handles"},
        {"metadata_bytes", "host_event_args_bytes"},
        {"readers", "host_file_readers"},
        {"chunk_bytes", "host_file_chunk_bytes"},
        {"whole_read_bytes", "host_file_whole_read_bytes"},
        {"envelope_bytes", "host_fetch_envelope_bytes"},
      ].sort)
      graph.capability_package_ids.should eq(Set{"ruby:lib/mochi_builtin_files.rb"})
      plain.manifest.capabilities.should eq([] of String)
      direct.manifest.capabilities.should eq(["files"])
      direct.manifest.capabilities.should_not contain("drag")
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

describe "qualified helper constants" do
  it "loads helpers referenced only by lowered row expressions" do
    root = File.join(Dir.tempdir, "mochi_row_helpers_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      html = %({each RowData.items as row, key: RowKey.id(row)}{if RowGate.allowed?(row)}<button onclick="{pick(RowEvent.id(row))}">{RowLabel.text(row)}</button>{end}{end})
      each = EachProcessor.process(html)
      generator = ComponentGenerator.new
      manifest = generator.generate("ProbeRoot", "probe-root", "", each.html, each_blocks: each.each_blocks)
      component = dependency_component(root, "probe-root", "ProbeRoot", "class ProbeRoot\nend\n")
      component.original_source = "class ProbeRoot\n def html\n %q(#{html})\n end\nend"
      component.ruby_code = EachMethodGenerator.inject_methods_into_class(component.ruby_code, "ProbeRoot", generator.each_row_templates)
      component.manifest = manifest
      names = ["RowData", "RowKey", "RowGate", "RowEvent", "RowLabel"]
      sources = (names + ["UnusedRowHelper"]).map do |name|
        dependency_prelude(root, "lib/#{name}.rb", "module #{name}\nend")
      end
      graph = dependency_graph(root, [component], sources)
      expected = names.map { |name| "ruby:lib/#{name}.rb" }.sort
      graph.package("component:probe-root").not_nil!.dependencies.sort.should eq(expected)
      graph.order.should_not contain("ruby:lib/UnusedRowHelper.rb")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps equal leaf names in separate packages and follows the actual namespace" do
    root = File.join(Dir.tempdir, "mochi_helper_scope_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(root, "lib"))
    begin
      record = dependency_prelude(root, "lib/record.rb", "module RecordData\n BASE = 7\n def self.base; BASE; end\nend")
      other = dependency_prelude(root, "lib/other.rb", "module OtherData\n BASE = 99\n def self.base; BASE; end\nend")
      global = dependency_prelude(root, "lib/global.rb", "BASE = 123")
      component = dependency_component(root, "probe-root", "ProbeRoot", "class ProbeRoot\n def value; RecordData::BASE; end\nend", "<p>{RecordData::BASE}</p>")
      symbols = TreeSitter::SourceSymbolExtractor.extract(record.source)
      symbols.exports.should eq(["RecordData", "RecordData::BASE"])
      symbols.exports.should_not contain("BASE")
      graph = dependency_graph(root, [component], [record, other, global])
      node = graph.packages[MochiPackaging::PackageGraph.component_package_id("probe-root")]
      node.dependencies.should contain(MochiPackaging::PackageGraph.ruby_package_id("lib/record.rb"))
      node.dependencies.should_not contain(MochiPackaging::PackageGraph.ruby_package_id("lib/other.rb"))
      node.dependencies.should_not contain(MochiPackaging::PackageGraph.ruby_package_id("lib/global.rb"))
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
