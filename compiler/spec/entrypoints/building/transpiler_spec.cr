require "spec"
require "file_utils"
require "json"
require "../../../src/entrypoints/building/transpiler"
require "../../../src/gvm/mrbc_compiler"

# These helpers normally live in src/mochi.cr. The spec only exercises
# Compiler#transpile_component, so keep the progress output quiet.
def print_cmp_start_separator(tag_name : String, i : Int32)
end

def print_cmp_end_seperator(tag_name : String, i : Int32)
end

private def transpile_source(source : String, class_name : String) : MochiComponent
  path = File.join(Dir.tempdir, "mochi_transpile_#{class_name}_#{Random.rand(1_000_000)}.rb")
  component = Compiler.new.transpile_component(source, 1, path)
  component.should_not be_nil
  component.not_nil!
end

private def temp_output_dir(prefix : String) : String
  dir = File.join(Dir.tempdir, "#{prefix}_#{Random.rand(1_000_000)}")
  Dir.mkdir_p(dir)
  dir
end

private def transpile_file_source(source : String, name : String) : TranspileFileResult
  path = File.join(Dir.tempdir, "mochi_transpile_file_#{name}_#{Random.rand(1_000_000)}.rb")
  Compiler.new.transpile_file(source, path, 1)
end

describe Compiler do
  describe "#transpile_component" do
    it "allows a component without a css method and injects helpers after the class body" do
      source = <<-RUBY
class BareComponent
  @flag = false
  @tag_name = "x-bare"

  def html
    %Q{
      {if @flag}<span>on</span>{end}
      <div class="box {if @flag}on{end}">hi</div>
    }
  end

  def increment
    @label = "🎉"
    @flag = !@flag
  end
end
RUBY

      component = transpile_source(source, "BareComponent")
      ruby = component.ruby_code

      component.manifest.css.should eq("")
      ruby.should_not contain("def html")
      ruby.should_not contain("def css")
      ruby.should_not contain("{end}")
      ruby.should contain("🎉")
      ruby.should contain("def __mochi_cond_0")
      ruby.should contain("def __mochi_attr_cond_0")

      increment_at = ruby.index("def increment").not_nil!
      ruby.index("def __mochi_cond_0").not_nil!.should be > increment_at
      ruby.index("def __mochi_attr_cond_0").not_nil!.should be > increment_at
    end

    it "compiles method-call bindings and direct ivar bindings" do
      source = <<-RUBY
class MethodBindings
  @tag_name = "x-method-bindings"
  @flag = false
  @label = "box"
  @box_class = "direct"

  def html
    %Q{<div class="box {box_class}" data-label="{@label}" data-direct="{@box_class}">{@label}</div>}
  end

  def box_class
    @flag ? "on" : "off"
  end

  def toggle
    @flag = !@flag
  end
end
RUBY

      component = transpile_source(source, "MethodBindings")
      manifest = component.manifest

      class_binding = manifest.bindings.find! { |binding| binding.kind == "attr" && binding.attr_name == "class" }
      class_binding.getter_expr.should eq("box_class")

      label_attr = manifest.bindings.find! { |binding| binding.kind == "attr" && binding.attr_name == "data-label" }
      label_attr.getter_expr.should eq("@label")

      direct_class = manifest.bindings.find! { |binding| binding.kind == "attr" && binding.attr_name == "data-direct" }
      direct_class.getter_expr.should eq("@box_class")

      label_text = manifest.bindings.find! { |binding| binding.kind == "html" }
      label_text.getter_expr.should eq("@label")

      component.ruby_code.should contain("def #{class_binding.getter_sym}; box_class; end")
      component.ruby_code.should contain("def #{label_attr.getter_sym}; @label; end")
      component.ruby_code.should contain("def #{direct_class.getter_sym}; @box_class; end")
      component.ruby_code.should contain("def box_class")
    end

    it "treats attr_reader and attr_accessor names as bindable methods" do
      source = <<-RUBY
class ReaderComponent
  @tag_name = "x-reader"
  @count = 0
  @label = "reader"

  attr_reader :count
  attr_accessor :label

  def html
    %Q{<p>{count} {@label}</p>}
  end

  def increment
    @count += 1
  end
end
RUBY

      component = transpile_source(source, "ReaderComponent")
      manifest = component.manifest
      reader = manifest.bindings.find! { |binding| binding.getter_expr == "count" }
      direct = manifest.bindings.find! { |binding| binding.getter_expr == "@label" }

      component.ruby_code.should contain("def #{reader.getter_sym}; count; end")
      component.ruby_code.should contain("def #{direct.getter_sym}; @label; end")
    end

    it "raises when a bare binding references an undefined method" do
      source = <<-RUBY
class UndefinedBinding
  @tag_name = "x-undefined-binding"

  def html
    %Q{<p>{missing_value}</p>}
  end
end
RUBY

      expect_raises(Exception, /UndefinedBinding.*missing_value/) do
        transpile_source(source, "UndefinedBinding")
      end
    end

    if real_mrbc = MrbcCompiler.find_mrbc
      it "writes a valid .chi and an empty css manifest entry for a css-less component" do
        source = <<-RUBY
class BareComponent
  @tag_name = "x-bare"

  def html
    %Q{<div>plain</div>}
  end
end
RUBY

        component = transpile_source(source, "BareComponent")
        output = temp_output_dir("mochi_cssless_spec")

        begin
          compiler = MrbcCompiler.new(mrbc_path: real_mrbc)
          compiler.compile([component], output)

          chi_path = File.join(output, "components", "x-bare.chi")
          File.exists?(chi_path).should be_true
          File.read(chi_path).includes?("MATZ").should be_true

          json = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
          bare = json["components"].as_a.find { |entry| entry.as_h["tag_name"].as_s == "x-bare" }
          bare.should_not be_nil
          bare.not_nil!.as_h["css"].as_s.should eq("")
        ensure
          FileUtils.rm_rf(output)
        end
      end
    end

    it "raises when an event handler is not defined on the component" do
      source = <<-RUBY
class BadHandler
  @tag_name = "x-bad-handler"

  def html
    %Q{<button onclick="{missing_handler}">x</button>}
  end
end
RUBY

      expect_raises(Exception, /BadHandler.*missing_handler/) do
        transpile_source(source, "BadHandler")
      end
    end

    it "raises when the template contains an unclosed placeholder" do
      source = <<-RUBY
class BadPlaceholder
  @tag_name = "x-bad-placeholder"

  def html
    %Q{<div>Hello {@broken</div>}
  end
end
RUBY

      expect_raises(Exception, /BadPlaceholder.*unclosed template placeholder/) do
        transpile_source(source, "BadPlaceholder")
      end
    end

    it "raises when the template contains an empty placeholder" do
      source = <<-RUBY
class BadEmptyPlaceholder
  @tag_name = "x-bad-empty-placeholder"

  def html
    %Q[<div>{}</div>]
  end
end
RUBY

      expect_raises(Exception, /BadEmptyPlaceholder.*empty template placeholder/) do
        transpile_source(source, "BadEmptyPlaceholder")
      end
    end

    it "raises when the template contains a stray closing brace" do
      source = <<-RUBY
class BadStrayBrace
  @tag_name = "x-bad-stray-brace"

  def html
    %Q[<div>Hello }</div>]
  end
end
RUBY

      expect_raises(Exception, /BadStrayBrace.*stray '}'/) do
        transpile_source(source, "BadStrayBrace")
      end
    end

    it "reports the original Ruby file and span for an invalid expression" do
      source = <<-RUBY
class BadExpression
  @tag_name = "x-bad-expression"
  @value = 1

  def html
    %Q{<p>{@value + }</p>}
  end
end
RUBY

      expect_raises(Exception, /\.rb:6:12: invalid Ruby expression/) do
        transpile_source(source, "BadExpression")
      end
    end

    it "rejects backtick commands in method bodies with the original file and method" do
      source = <<-RUBY
class BadShell
  @tag_name = "x-bad-shell"

  def refresh
    `echo hi`
  end

  def html
    %Q{<div>hi</div>}
  end
end
RUBY

      path = File.join(Dir.tempdir, "mochi_backtick_#{Random.rand(1_000_000)}.rb")
      error = expect_raises(Exception) do
        Compiler.new.transpile_file(source, path, 1, "lib/bad_shell.rb")
      end
      error.message.to_s.should match(/lib\/bad_shell\.rb:5.*method 'refresh'/)
      error.message.to_s.should contain("backtick command execution is not supported")
    end

    it "reports Ruby paths relative to the build's temporary source tree" do
      Compiler.source_display_path(
        "/repo/build/pre_tp/lib/screens/counter.rb",
        "/repo/build/pre_tp/lib"
      ).should eq("lib/screens/counter.rb")
      Compiler.source_display_path("/elsewhere/plain.rb", "/repo/build/pre_tp/lib")
        .should eq("/elsewhere/plain.rb")
    end

    it "records the source file, class line, and method lines in the manifest" do
      source = <<-RUBY
class SourceMap
  @tag_name = "x-source-map"

  def html
    %Q{<p>hi</p>}
  end

  def increment
    @count = 1
  end
end
RUBY

      path = File.join(Dir.tempdir, "mochi_source_map_#{Random.rand(1_000_000)}.rb")
      component = Compiler.new.transpile_component(source, 1, path, "lib/source_map.rb").not_nil!
      component.source_path.should eq("lib/source_map.rb")
      component.manifest.source_file.should eq("lib/source_map.rb")
      component.manifest.source_line.should eq(1)
      component.manifest.method_lines["html"].should eq(4)
      component.manifest.method_lines["increment"].should eq(8)
    end

    it "raises when a component exceeds the GVM instance variable limit" do
      assignments = (0...257).map { |index| "    @v#{index} = 0\n" }.join

      source = <<-RUBY
class TooManyVars
  @tag_name = "x-many-vars"

  def initialize
#{assignments}  end

  def html
    %Q{<div>hi</div>}
  end
end
RUBY

      expect_raises(Exception, /TooManyVars.*257 instance variables/) do
        transpile_source(source, "TooManyVars")
      end
    end

    it "raises when @tag_name does not contain a hyphen" do
      source = <<-RUBY
class InvalidTag
  @tag_name = "invalidtag"

  def html
    %Q{<div>hi</div>}
  end
end
RUBY

      expect_raises(Exception, /InvalidTag.*must contain a hyphen/) do
        transpile_source(source, "InvalidTag")
      end
    end

    it "supports escaped double braces {{ and }} and bare bind:value=\"@ivar\"" do
      source = <<-RUBY
class ErgonomicComponent
  @tag_name = "x-ergonomic"
  @query = ""

  def html
    %Q{
      <div>Literal {{braces}} and <input bind:value="@query"></div>
    }
  end
end
RUBY

      component = transpile_source(source, "ErgonomicComponent")
      component.manifest.html_template.should contain("Literal {braces}")
      prop = component.manifest.bindings.find! { |b| b.kind == "prop" }
      prop.getter_expr.should eq("@query")
      prop.setter_sym.should eq("__mochi_set_query")
    end

    it "registers delegated events and loop metadata inside {each} blocks" do
      source = <<-RUBY
class EachEventsComponent
  @tag_name = "x-each-events"
  @queues = []

  def toggle_pause(q)
  end

  def html
    %Q{
      <ul>
        {each @queues as q, idx}
          <li><button onclick="{toggle_pause(q)}">{q.name}</button></li>
        {end}
      </ul>
    }
  end
end
RUBY

      component = transpile_source(source, "EachEventsComponent")
      each_binding = component.manifest.bindings.find! { |b| b.kind == "each" }
      each_binding.attr_name.should eq("q,idx")
      each_binding.getter_expr.should eq("__mochi_each_0_rows")
      each_binding.template_text.not_nil!.should contain("data-mochi-click=\"__mochi_each_0_ev_1\"")
      each_binding.each_rows.not_nil!.events.first.handler.should eq("toggle_pause")
      component.manifest.event_names.should contain("click")
      component.ruby_code.should contain("def __mochi_each_0_rows")
      component.ruby_code.should contain("def __mochi_each_0_ev_1(")
      component.ruby_code.should contain("toggle_pause(q)")
      component.ruby_code.should_not contain("data-mochi-args")
    end

    it "keeps repeated row event arguments attached to their own element" do
      source = <<-RUBY
class RepeatedRowEvents
  @tag_name = "x-repeated-row-events"
  @queues = []

  def pick(value)
  end

  def html
    %Q{
      <div>
        {each @queues as q}
          <button class="first" onclick="{pick(q[:first])}">first</button>
          <button class="second" onclick="{pick(q[:second])}">second</button>
        {end}
      </div>
    }
  end
end
RUBY

      component = transpile_source(source, "RepeatedRowEvents")
      binding = component.manifest.bindings.find! { |entry| entry.kind == "each" }
      row = binding.each_rows.not_nil!
      row.events.size.should eq(2)
      row.events.map(&.handler).should eq(["pick", "pick"])
      row.events.map { |event| event.args.map(&.value) }.should eq([
        ["q[:first]"],
        ["q[:second]"],
      ])
      row.events[0].wrapper_sym.should_not eq(row.events[1].wrapper_sym)
    end

    it "rejects unresolved names in list row bindings and event arguments" do
      self_source = <<-RUBY
class SelfRow
  @tag_name = "x-self-row"
  @items = []

  def label_for(item)
    item.to_s
  end

  def html
    %Q{
      <div>
        {each @items as item}
          <span>{self.label_for(item)}</span>
        {end}
      </div>
    }
  end
end
RUBY

      transpile_source(self_source, "SelfRow").manifest.bindings
        .any? { |binding| binding.kind == "each" }.should be_true

      binding_source = <<-RUBY
class BadRowBinding
  @tag_name = "x-bad-row-binding"
  @items = []

  def html
    %Q{
      <ul>
        {each @items as item}
          <li><button>{missing_helper(item)}</button></li>
        {end}
      </ul>
    }
  end
end
RUBY

      expect_raises(Exception, /list row uses undefined name 'missing_helper'/) do
        transpile_source(binding_source, "BadRowBinding")
      end

      argument_source = <<-RUBY
class BadRowArgument
  @tag_name = "x-bad-row-argument"
  @items = []

  def html
    %Q{
      <div>
        {each @items as item}
          <button onclick="{pick(missing)}">pick</button>
        {end}
      </div>
    }
  end

  def pick(value)
  end
end
RUBY

      expect_raises(Exception, /list row uses undefined name 'missing'/) do
        transpile_source(argument_source, "BadRowArgument")
      end
    end

    if real_mrbc = MrbcCompiler.find_mrbc
      it "compiles prelude.chi and topologically sorts child components before parents" do
        parent_src = <<-RUBY
class ParentBox
  @tag_name = "a-parent-box"
  def html
    %Q{<div><z-child-item></z-child-item></div>}
  end
end
RUBY
        child_src = <<-RUBY
class ChildItem
  @tag_name = "z-child-item"
  def html
    %Q{<span>{SharedData.label}</span>}
  end
end
RUBY
        prelude_src = <<-RUBY
class SharedData
  def self.label
    "shared"
  end
end
RUBY

        parent_comp = transpile_source(parent_src, "ParentBox")
        child_comp = transpile_source(child_src, "ChildItem")
        output = temp_output_dir("mochi_topo_prelude_spec")

        begin
          compiler = MrbcCompiler.new(mrbc_path: real_mrbc)
          compiler.compile([parent_comp, child_comp], output, prelude_src)

          File.exists?(File.join(output, "components", "prelude.chi")).should be_true
          json = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
          json["prelude"].as_s.should eq("prelude.chi")
          tags = json["components"].as_a.map { |entry| entry.as_h["tag_name"].as_s }
          tags.should eq(["z-child-item", "a-parent-box"])
        ensure
          FileUtils.rm_rf(output)
        end
      end
    end
  end

  describe "#transpile_file" do
    it "compiles every component class and keeps helper code in one helper unit" do
      source = <<-RUBY
class RowLabels
  def self.label(value)
    "row-" + value.to_s
  end
end

class RowChip
  @tag_name = "x-row-chip"
  def html
    %Q{<span class="row-only">{RowLabels.label("chip")}</span>}
  end
end

class ScreenPanel
  @tag_name = "x-screen-panel"
  @count = 0
  def html
    %Q{<div class="screen-only">{@count}</div>}
  end
end
RUBY

      result = transpile_file_source(source, "MultiComponentFile")
      result.components.map { |component| component.manifest.tag_name }.should eq(["x-row-chip", "x-screen-panel"])
      result.components.map { |component| component.manifest.class_name }.should eq(["RowChip", "ScreenPanel"])

      row = result.components[0]
      screen = result.components[1]
      row.ruby_code.should contain("class RowChip")
      row.ruby_code.should_not contain("class ScreenPanel")
      row.ruby_code.should_not contain("class RowLabels")
      row.manifest.html_template.should contain("row-only")
      row.manifest.html_template.should_not contain("screen-only")

      screen.ruby_code.should contain("class ScreenPanel")
      screen.ruby_code.should_not contain("class RowChip")
      screen.manifest.html_template.should_not contain("row-only")

      helper = result.helper.not_nil!
      helper.source.should contain("class RowLabels")
      helper.source.should_not contain("class RowChip")
      helper.source.should_not contain("class ScreenPanel")
      row.manifest.helper_chi.should eq(helper.key)
      screen.manifest.helper_chi.should eq(helper.key)
    end

    it "finds a component after an ordinary helper class" do
      source = <<-RUBY
class PlainHelper
  def self.value
    "plain"
  end
end

class ActualComponent
  @tag_name = "x-actual"
  def html
    %Q{<span>{PlainHelper.value}</span>}
  end
end
RUBY

      result = transpile_file_source(source, "HelperBeforeComponent")
      result.components.size.should eq(1)
      result.components.first.manifest.tag_name.should eq("x-actual")
      result.helper.not_nil!.source.should contain("class PlainHelper")
    end

    it "keeps class-local tags and css out of sibling components" do
      source = <<-RUBY
class FirstCard
  @tag_name = "x-first-card"
  def html
    %Q{<span class="first-only">first</span>}
  end
  def css
    ".first-only { color: red; }"
  end
end

class SecondCard
  @tag_name = "x-second-card"
  def html
    %Q{<span class="second-only">second</span>}
  end
  def css
    ".second-only { color: blue; }"
  end
end
RUBY

      result = transpile_file_source(source, "SiblingCards")
      result.components.map { |component| component.manifest.tag_name }.should eq(["x-first-card", "x-second-card"])
      first = result.components[0]
      second = result.components[1]
      first.manifest.css.should contain("first-only")
      first.manifest.css.should_not contain("second-only")
      second.manifest.css.should contain("second-only")
      second.manifest.css.should_not contain("first-only")
    end

    it "uses the GVM class symbol for namespaced components" do
      source = <<-RUBY
module UI
  class Panel
    @tag_name = "x-ns-panel"
    def html
      %Q{<span>panel</span>}
    end
  end
end
RUBY

      result = transpile_file_source(source, "NamespacedComponent")
      component = result.components.first
      component.manifest.class_name.should eq("Panel")
      component.ruby_code.should contain("module UI")
      component.ruby_code.should contain("class Panel")
    end

    it "rejects duplicate component tags with both source locations" do
      source = <<-RUBY
class FirstDuplicate
  @tag_name = "x-duplicate"
  def html
    %Q{<span>first</span>}
  end
end

class SecondDuplicate
  @tag_name = "x-duplicate"
  def html
    %Q{<span>second</span>}
  end
end
RUBY

      error = expect_raises(Exception) { transpile_file_source(source, "DuplicateTags") }
      error.message.not_nil!.should contain("Duplicate component tag 'x-duplicate'")
      error.message.not_nil!.should contain(":1")
      error.message.not_nil!.should contain(":8")
    end

    it "rejects duplicate GVM class symbols across namespaces" do
      source = <<-RUBY
module One
  class Panel
    @tag_name = "x-one-panel"
    def html
      %Q{<span>one</span>}
    end
  end
end

module Two
  class Panel
    @tag_name = "x-two-panel"
    def html
      %Q{<span>two</span>}
    end
  end
end
RUBY

      error = expect_raises(Exception) { transpile_file_source(source, "DuplicateClasses") }
      error.message.not_nil!.should contain("Duplicate component class 'Panel'")
      error.message.not_nil!.should contain(":2")
      error.message.not_nil!.should contain(":11")
    end

    if real_mrbc = MrbcCompiler.find_mrbc
      it "emits one helper bytecode file shared by both components" do
        source = <<-RUBY
class SharedLabel
  def self.value
    "shared"
  end
end

class FirstBox
  @tag_name = "x-first-box"
  def html
    %Q{<span>{SharedLabel.value}</span>}
  end
end

class SecondBox
  @tag_name = "x-second-box"
  def html
    %Q{<span>{SharedLabel.value}</span>}
  end
end
RUBY

        result = transpile_file_source(source, "SharedHelperFile")
        helper = result.helper.not_nil!
        output = temp_output_dir("mochi_multi_class_spec")

        begin
          compiler = MrbcCompiler.new(mrbc_path: real_mrbc)
          compiler.compile(result.components, output, "", [helper])

          File.exists?(File.join(output, "components", helper.key)).should be_true
          compiler.helper_chi_paths.should eq([File.join(output, "components", helper.key)])
          compiler.chi_paths.size.should eq(2)

          json = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
          json["components"].as_a.each do |entry|
            entry.as_h["helper_chi"].as_s.should eq(helper.key)
          end
        ensure
          FileUtils.rm_rf(output)
        end
      end
    end
  end
end
