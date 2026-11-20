require "spec"
require "file_utils"
require "json"
require "../../../src/entrypoints/building/builder_man"
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
    it "reports malformed attribute expressions at their authored line in every scope" do
      [
        %q(<p title="{@field["label"]"></p>),
        %q({if @open}<p title="{@field["label"]"></p>{end}),
        %q({each @rows as row}<p title="{row["label"]"></p>{end}),
        %q(<p class="{if @field[}active{end}"></p>),
        %q(<button onclick="{pick(@field[)}">Pick</button>),
      ].each do |template|
        source = "class BrokenQuotes\n  @tag_name = \"broken-quotes\"\n  def html\n    %q~#{template}~\n  end\nend\n"
        error = expect_raises(TemplateExpressionError) { transpile_source(source, "BrokenQuotes") }
        error.message.to_s.should match(/\.rb:4:/)
        error.message.to_s.should match(/unclosed template placeholder|invalid Ruby expression/)
        error.message.to_s.should match(/field|row/)
      end
    end

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

    it "extracts declared typed props and installs them around initialize" do
      source = <<-RUBY
class TypedBadge
  @tag_name = "typed-badge"
  prop :label, String, default: "unset"
  prop :count, Integer, default: 0
  prop :rows, Array, default: []

  def initialize
    @ready = @count
  end

  def html
    %Q{<span>{@label}</span><span>{@count}</span><span>{@rows.length}</span>}
  end
end
RUBY

      component = transpile_source(source, "TypedBadge")
      component.manifest.props.map(&.name).should eq(["label", "count", "rows"])
      component.manifest.props[0].type.should eq("string")
      component.manifest.props[0].default.should be_true
      component.manifest.props[0].default_code.should eq(%("unset"))
      component.manifest.props[1].default_code.should eq("0")
      component.manifest.props[2].default_code.should eq("[]")

      ruby = component.ruby_code
      ruby.should contain("def __mochi_apply_props(__mochi_props, __mochi_initial)")
      ruby.should contain(%(@label = __mochi_props["label"]))
      ruby.should contain(%(@label = "unset"))
      ruby.should contain("@count = 0")
      ruby.should contain("@rows = []")
    end

    it "extracts declared child events and injects the emit bridge" do
      source = <<-RUBY
class EventRow
  @tag_name = "event-row"
  event :select, id: Integer, label: String

  def html
    %Q{<button onclick="{choose}">Choose</button>}
  end

  def choose
    emit :select, id: 7, label: "Seven"
  end
end
RUBY

      component = transpile_source(source, "EventRow")
      component.manifest.emits.map(&.name).should eq(["select"])
      component.manifest.emits[0].payload.map(&.name).should eq(["id", "label"])
      component.manifest.emits[0].payload.map(&.type).should eq(["integer", "string"])
      component.manifest.emits[0].source_line.should eq(3)

      ruby = component.ruby_code
      ruby.should contain("def emit(__mochi_event, __mochi_payload = {})")
      ruby.should contain("Mochi.emit_child(__mochi_event.to_s, __mochi_payload)")
      ruby.should contain("def choose")
    end

    it "compiles on: child event bindings as component connections" do
      source = <<-RUBY
class EventParent
  @tag_name = "event-parent"
  @selected

  def html
    %Q{<event-row on:select="{row_selected($event)}"></event-row>}
  end

  def row_selected(payload)
    @selected = payload[:id]
  end
end
RUBY

      component = transpile_source(source, "EventParent")
      event = component.manifest.events.find! { |candidate| candidate.event == "select" }
      event.component.should be_true
      event.method_sym.should eq("row_selected")
      event.args.size.should eq(1)
      event.args[0].kind.should eq("event")

      component.manifest.html_template.should contain(%Q(data-mochi-select="row_selected"))
      component.manifest.html_template.should contain("data-mochi-args-select=")
      component.manifest.html_template.should_not contain("on:select")
    end

    it "compiles synchronous modifiers and named refs" do
      source = <<-RUBY
class ModalSlice
  @tag_name = "modal-slice"

  def html
    %Q{
      <div ref="dialog" data-mochi-focus-trap>
        <a href="#save" onclick.prevent.stop.self="{save}">Save</a>
      </div>
    }
  end

  def save
  end
end
RUBY

      component = transpile_source(source, "ModalSlice")
      event = component.manifest.events.find! { |candidate| candidate.event == "click" }
      event.modifiers.should eq(["prevent", "stop", "self"])

      component.manifest.html_template.should contain(%Q(data-mochi-click="save"))
      component.manifest.html_template.should contain(%Q(data-mochi-modifiers-click="prevent,stop,self"))
      component.manifest.html_template.should contain(%Q(data-mochi-ref="dialog"))
      component.manifest.html_template.should_not contain(%Q( ref="dialog"))
    end

    it "keeps modifiers on each-row events" do
      source = <<-RUBY
class RowModifierSlice
  @tag_name = "row-modifier-slice"
  @items = []

  def pick(value)
  end

  def html
    %Q{
      <ul>
        {each @items as item}
          <li><button onclick.stop="{pick(item)}">Pick</button></li>
        {end}
      </ul>
    }
  end
end
RUBY

      component = transpile_source(source, "RowModifierSlice")
      each_binding = component.manifest.bindings.find! { |binding| binding.kind == "each" }
      each_binding.template_text.not_nil!.should contain(%Q(data-mochi-modifiers-click="stop"))
      each_binding.each_rows.not_nil!.events.first.modifiers.should eq(["stop"])
    end

    it "rejects a user emit method when child events are declared" do
      source = <<-RUBY
class BadEmitter
  @tag_name = "bad-emitter"
  event :select, id: Integer

  def html
    %Q{<span>bad</span>}
  end

  def emit
    nil
  end
end
RUBY

      path = File.join(Dir.tempdir, "mochi_bad_emit_#{Random.rand(1_000_000)}.rb")
      expect_raises(Exception, /cannot define a method named emit/) do
        Compiler.new.transpile_component(source, 1, path)
      end
    end

    it "reports a prop declaration error with the component source line" do
      source = <<-RUBY
class BadProp
  @tag_name = "bad-prop"
  prop :label, Symbol

  def html
    %Q{<span>bad</span>}
  end
end
RUBY

      path = File.join(Dir.tempdir, "mochi_bad_prop_#{Random.rand(1_000_000)}.rb")
      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /unsupported type Symbol/) do
        Compiler.new.transpile_component(source, 1, path)
      end
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

      label_text = manifest.bindings.find! { |binding| binding.kind == "text" }
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
          bare_index = json["components"].as_a.find { |entry| entry.as_h["tag_name"].as_s == "x-bare" }
          bare_index.should_not be_nil
          bare = JSON.parse(File.read(File.join(output, bare_index.not_nil!.as_h["descriptor"].as_s)))
          bare.as_h["css"].as_s.should eq("")
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

    it "emits evaluated row keys and validates key expressions" do
      source = <<-RUBY
class KeyedRows
  @tag_name = "x-keyed-rows"
  @groups = []

  def html
    %Q{
      <ul>
        {each @groups as group, key: group["id"]}
          <li>{group["name"]}</li>
        {end}
      </ul>
    }
  end
end
RUBY

      component = transpile_source(source, "KeyedRows")
      row = component.manifest.bindings.find! { |binding| binding.kind == "each" }.each_rows.not_nil!
      row.key_expression.should eq(%Q{group["id"]})
      component.ruby_code.should contain(%Q{(group["id"])})
      component.ruby_code.should contain("__mochi_rows_0.push([")

      bad_source = <<-RUBY
class BadRowKey
  @tag_name = "x-bad-row-key"
  @items = []

  def html
    %Q{
      <ul>
        {each @items as item, key: missing_key}
          <li>{item["label"]}</li>
        {end}
      </ul>
    }
  end
end
RUBY

      expect_raises(Exception, /list row uses undefined name 'missing_key'/) do
        transpile_source(bad_source, "BadRowKey")
      end
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
            descriptor = JSON.parse(File.read(File.join(output, entry.as_h["descriptor"].as_s)))
            descriptor.as_h["helper_chi"].as_s.should eq(helper.key)
          end
        ensure
          FileUtils.rm_rf(output)
        end
      end
    end
  end
end

private def write_portable_spec_declaration(project : String, root = "portable-screen") : Nil
  declaration = {
    version:      PortableProject::VERSION,
    root:         root,
    app_id:       "org.mochi.spec",
    display_name: "Portable spec",
    fonts:        {} of String => String,
  }
  File.write(File.join(project, PortableProject::FILE_NAME), declaration.to_json)
end

private def write_portable_spec_screen(project : String, content : String, state = "") : Nil
  File.write(File.join(project, "lib/PortableScreen.rb"), <<-RUBY)
    class PortableScreen
      @tag_name = "portable-screen"
      #{state}

      def html
        %q{
          #{content}
        }
      end

      def css
        %q{
          @import "styles/shared.css";
          .screen { gap: 4px; }
        }
      end
    end
    RUBY
end

private def with_portable_spec_project(&)
  project = temp_output_dir("mochi_portable_spec")
  FileUtils.mkdir_p(File.join(project, "lib/styles"))
  File.write(File.join(project, "lib/styles/base.css"), ".screen { padding: 8px; }")
  File.write(File.join(project, "lib/styles/shared.css"), <<-CSS)
    @import "base.css";
    .screen {
      display: flex;
    }
    CSS
  File.write(File.join(project, "lib/WebScreen.rb"), <<-RUBY)
    class WebScreen
      @tag_name = "web-screen"

      def html
        %q{<main class="grid"><input type="search"></main>}
      end

      def css
        %q{
          .grid {
            display: grid;
          }
        }
      end
    end
    RUBY
  File.write(File.join(project, "index.html"), "<web-screen></web-screen>")
  write_portable_spec_screen(project, %q(<div class="screen"><span>Stations</span></div>))
  write_portable_spec_declaration(project)
  yield project
ensure
  FileUtils.rm_rf(project) if project
end

private def compile_portable_spec(project : String, target : RenderTarget, before_emit : Proc(Nil)? = nil) : String
  output = File.join(project, target.to_s.downcase)
  builder = BuilderMan.new(project, output)
  builder.copy_ruby_code_to_pre_tp
  staged = builder.pre_tp_dir
  Compiler.new(render_target: target, portable_project: PortableProject.read(project)).transpile_directory(
    File.join(staged, "lib"), output, builder, project_dir: staged, asset_root: project, before_emit: before_emit
  )
  output
ensure
  builder.try(&.cleanup)
end

private def portable_diagnostic(project : String, message : String) : Nil
  diagnostics = RenderTarget.values.map do |target|
    expect_raises(Exception, message) { compile_portable_spec(project, target) }.message
  end
  diagnostics[0].should eq(diagnostics[1])
end

describe "Portable build validation" do
  it "compiles the declared root and its ordered shared styles on both targets" do
    with_portable_spec_project do |project|
      # The HTML entry and a template comment name an unrelated screen.
      write_portable_spec_screen(project, %q(<div class="screen"><!-- <web-screen> --><span>Stations</span></div>))
      dom = compile_portable_spec(project, RenderTarget::Dom)
      desktop = compile_portable_spec(project, RenderTarget::Desktop)
      manifest = JSON.parse(File.read(File.join(dom, "mochi-manifest.json")))
      manifest["entry_packages"].as_a.map(&.as_s).should eq(["component:portable-screen"])
      manifest["packages"].as_h.keys.should eq(["component:portable-screen"])
      manifest["resources"].as_h.size.should eq(2)
      scene = JSON.parse(File.read(File.join(desktop, "scene.json")))
      scene["tag"].as_s.should eq("portable-screen")
      scene["styles"].as_a.map { |rule| rule.as_h.keys }.should eq([["padding"], ["flex"], ["gap"]])
      File.read(File.join(dom, "components/portable-screen.chi")).should eq(File.read(File.join(desktop, "components/portable-screen.chi")))
    end
  end

  it "normalizes ordered rules and compiles layout with the same root constraints" do
    with_portable_spec_project do |project|
      declaration_path = File.join(project, PortableProject::FILE_NAME)
      declaration = JSON.parse(File.read(declaration_path)).as_h
      declaration["window"] = JSON.parse(%q({"inset":24,"max_width":520}))
      File.write(declaration_path, declaration.to_json)
      write_portable_spec_screen(project, %q(<div class="second screen second"><button class="screen second">Open</button></div>))
      stylesheet = File.join(project, "lib/styles/base.css")
      File.write(stylesheet, ".screen { padding: 0008px; } .second { padding: 12px; width: 20px; }")
      root = File.join(project, "lib/PortableScreen.rb")
      File.write(root, File.read(root).sub("gap: 4px;", "gap: 4px; padding: 4px /* local */; width: auto;"))

      dom = compile_portable_spec(project, RenderTarget::Dom)
      native = compile_portable_spec(project, RenderTarget::Desktop)
      manifest = JSON.parse(File.read(File.join(dom, "mochi-manifest.json")))
      descriptor = JSON.parse(File.read(File.join(dom, "components/portable-screen.json")))
      imported = descriptor["style_resources"].as_a.map do |id|
        file = manifest["resources"][id.as_s]["file"].as_s
        File.read(File.join(dom, file))
      end
      imported[0].should contain(".screen{padding:8px;}")
      imported[0].should contain(".second{padding:12px;width:20px;min-width:20px;}")
      imported[1].should contain(".screen{display:flex;")
      descriptor["css"].as_s.should contain(".screen{gap:4px;padding:4px;width:auto;min-width:0;}")
      descriptor["css"].as_s.should contain("margin:24px;width:max(0px,calc(100% - 48px));max-width:520px")

      scene = JSON.parse(File.read(File.join(native, "scene.json")))
      scene["window"].should eq(declaration["window"])
      scene["style_lookup"]["screen"].as_a.map(&.as_i).should eq([0, 2, 3])
      scene["nodes"][0]["styles"].should eq(scene["nodes"][0]["nodes"][0]["styles"])
      scene["nodes"][0]["styles"].as_a.map(&.as_i).should eq([0, 1, 2, 3])
      scene["styles"][3]["padding"].as_i.should eq(4)
      scene["styles"][3]["width"].as_i.should eq(-1)

      declaration["window"] = JSON.parse(%q({"inset":-1}))
      File.write(declaration_path, declaration.to_json)
      portable_diagnostic(project, "mochi-portable.json: window inset must be 0–9999")
    end
  end

  it "checks grid in a second screen referenced only by an inactive branch" do
    with_portable_spec_project do |project|
      screen = File.join(project, "lib/WebScreen.rb")
      File.write(screen, File.read(screen).sub(%q(<main class="grid"><input type="search"></main>), %q(<div class="grid"><span>Web</span></div>)))
      write_portable_spec_screen(project, %q(<div>{if false}<web-screen></web-screen>{end}</div>))
      portable_diagnostic(project, "lib/WebScreen.rb:11: portable component 'WebScreen': unsupported CSS 'display: grid'")
    end
  end

  it "reports the original line in a nested shared stylesheet" do
    with_portable_spec_project do |project|
      File.write(File.join(project, "lib/styles/base.css"), "/* Café */\n\n.screen { gap: 4em; }\n")
      portable_diagnostic(project, "lib/styles/base.css:3: portable component 'PortableScreen': unsupported CSS 'gap: 4em'")
      File.write(File.join(project, "lib/styles/base.css"), ".screen { padding: 8px; }")
      fragment = File.join(project, "lib/styles/shared.css")
      File.write(fragment, File.read(fragment).sub("display: flex", "display: grid"))
      portable_diagnostic(project, "lib/styles/shared.css:3: portable component 'PortableScreen': unsupported CSS 'display: grid'")
    end
  end

  it "reports an unsupported host operation at its authored Ruby dependency call" do
    with_portable_spec_project do |project|
      File.write(File.join(project, "lib/station_source.rb"), <<-RUBY)
        module StationSource
          def self.label
            Mochi.host_async("layout", "measure", ["panel"], :received)
          end
        end
        RUBY
      write_portable_spec_screen(project, %q(<div><span>{station_label}</span></div>), "def station_label; StationSource.label; end")
      portable_diagnostic(project, %q(lib/station_source.rb:3: portable component 'PortableScreen': unsupported host operation Mochi.host_async("layout", "measure")))
    end
  end

  it "checks host operations inside inactive template expressions" do
    with_portable_spec_project do |project|
      write_portable_spec_screen(project, %q(<div>{if false}<span>{Mochi.storage_get("station")}</span>{end}</div>))
      portable_diagnostic(project, "lib/PortableScreen.rb:7: portable component 'PortableScreen': unsupported host operation Mochi.storage_get")
    end
  end

  it "checks font declarations and paths relative to the project" do
    with_portable_spec_project do |project|
      stylesheet = File.join(project, "lib/styles/base.css")
      File.write(stylesheet, ".screen { font-family: LocalFace, sans-serif; }")
      portable_diagnostic(project, "lib/styles/base.css:1: portable component 'PortableScreen': font family 'LocalFace' is missing from mochi-portable.json")

      path = File.join(project, PortableProject::FILE_NAME)
      declaration = JSON.parse(File.read(path)).as_h
      declaration["fonts"] = JSON.parse(%q({"LocalFace":"public/type/primary.woff2"}))
      File.write(path, declaration.to_json)
      portable_diagnostic(project, %q(mochi-portable.json: font "LocalFace" must be a local file at public/type/primary.woff2))
    end
  end

  it "preserves an existing bundle when the declared root is missing" do
    with_portable_spec_project do |project|
      write_portable_spec_declaration(project, "absent-screen")
      RenderTarget.values.each do |target|
        output = File.join(project, target.to_s.downcase)
        Dir.mkdir_p(output)
        manifest = File.join(output, "mochi-manifest.json")
        File.write(manifest, "prior output")
        prepare = -> { File.delete(manifest); nil }
        expect_raises(Exception, "mochi-portable.json: declared root <absent-screen> was not found") do
          compile_portable_spec(project, target, prepare)
        end
        File.read(manifest).should eq("prior output")
      end
    end
  end

  it "keeps grid and regular resource collection available in ordinary DOM builds" do
    with_portable_spec_project do |project|
      File.delete(File.join(project, PortableProject::FILE_NAME))
      icons = File.join(project, "icons")
      Dir.mkdir_p(icons)
      File.write(File.join(icons, "pin.svg"), %q(<svg xmlns="http://www.w3.org/2000/svg" id="mochi-icon"></svg>))
      index = File.join(project, "index.html")
      File.write(index, File.read(index) + %q(<span icon="pin"></span>))
      output = compile_portable_spec(project, RenderTarget::Dom)
      descriptor = JSON.parse(File.read(File.join(output, "components/web-screen.json")))
      descriptor["css"].as_s.should contain("display: grid")
      descriptor["html_template"].as_s.should contain("type=\"search\"")
      File.file?(File.join(output, "mochi-icons/pin.svg")).should be_true
    end
  end
end

describe "Portable template records" do
  it "projects DOM paths and native operands for Unicode text in nested scopes" do
    with_portable_spec_project do |project|
      template = <<-HTML
        <div>
          <!-- keeps a DOM position -->
          <span>É &amp; {first} · {last}</span><span>É &amp; {first} · {last}</span>
          {if true}
            <div>
              {if false}
                <span>Fallback</span>
              {else}
                {each [{"id" => 1, "active" => true}] as row, key: row["id"]}
                  <button class="station {if row['active']}selected{end}" onclick="{pick($event)}">Café &lt;{row['id']}&gt; {row['id']} &#123;safe&#125;</button>
                {end}
              {end}
            </div>
          {end}
        </div>
        HTML
      methods = <<-RUBY
        def first; "North"; end
        def last; "Bay"; end
        def pick(event); event; end
        RUBY
      write_portable_spec_screen(project, template, methods)

      desktop = compile_portable_spec(project, RenderTarget::Desktop)
      dom = compile_portable_spec(project, RenderTarget::Dom)
      scene_path = File.join(desktop, "scene.json")
      descriptor_path = File.join(dom, "components/portable-screen.json")
      scene = JSON.parse(File.read(scene_path))
      descriptor = JSON.parse(File.read(descriptor_path))
      scene["version"].as_i.should eq(DesktopScene::VERSION)
      scene.to_json.should_not contain("html_template")
      scene.to_json.should_not contain("if-anchor")
      scene.to_json.should_not contain("each-anchor")
      scene.to_json.should_not contain("\u{E002}")
      scene.to_json.should_not contain("\"path\":")

      labels = scene["nodes"][0]["nodes"].as_a.first(2)
      first, second = labels.map { |label| label["nodes"][0] }
      first["parts"].as_a.should eq(JSON.parse(%q(["É & ",{"binding":0}," · ",{"binding":1}])).as_a)
      second["parts"].as_a.should eq(JSON.parse(%q(["É & ",{"binding":2}," · ",{"binding":3}])).as_a)
      first["span"]["line"].should eq(second["span"]["line"])
      second["span"]["column"].as_i.should eq(first["span"]["column"].as_i + %q(É &amp; {first} · {last}</span><span>).size)
      first["span"]["file"].as_s.should eq("lib/PortableScreen.rb")
      first["id"].as_i.should be < second["id"].as_i
      descriptor["bindings"][0]["path"].as_a.map(&.as_i).should eq([0, 3, 0])
      descriptor["bindings"][2]["path"].as_a.map(&.as_i).should eq([0, 4, 0])

      outer = scene["nodes"][0]["nodes"][2]
      inner = outer["branches"][0][0]["nodes"][0]
      inner["branches"][0][0]["type"].as_s.should eq("label")
      each = inner["branches"][1][0]
      each["type"].as_s.should eq("each")
      row_button = each["nodes"][0]
      row_button["row_context"].as_bool.should be_true
      row_button["style_names"].as_a.should eq(JSON.parse(%q([{"slot":0}])).as_a)
      row_button["nodes"][0]["parts"].as_a.should eq(JSON.parse(%q(["Café <",{"slot":1},"> ",{"slot":2}," {safe}"])).as_a)

      other = File.join(project, "second checkout")
      Dir.mkdir(other)
      FileUtils.cp_r(File.join(project, "lib"), other)
      FileUtils.cp(File.join(project, PortableProject::FILE_NAME), other)
      other_dom = compile_portable_spec(other, RenderTarget::Dom)
      other_desktop = compile_portable_spec(other, RenderTarget::Desktop)
      File.read(File.join(other_desktop, "scene.json")).should eq(File.read(scene_path))
      File.read(File.join(other_dom, "components/portable-screen.json")).should eq(File.read(descriptor_path))
      file = "components/portable-screen.chi"
      bytes = File.read(File.join(desktop, file))
      [dom, other_dom, other_desktop].each { |bundle| File.read(File.join(bundle, file)).should eq(bytes) }
    end
  end
end

describe "Portable font resolution" do
  it "requires an exact weight and resolves ordered fallback faces and licenses" do
    with_portable_spec_project do |project|
      public_dir = File.join(project, "public")
      Dir.mkdir(public_dir)
      fixture = File.expand_path("../../../../e2e/fixtures/clay_inspector/public", __DIR__)
      %w[station-sans.woff2 station-sans-bold.woff2 station-symbols-bold.woff2 OFL.txt].each do |name|
        FileUtils.cp(File.join(fixture, name), public_dir)
      end
      write_portable_spec_screen(project, %q(<div class="screen"><span>Élan Ω</span><span class="bold">Élan Ω</span></div>))
      css_path = File.join(project, "lib/styles/base.css")
      File.write(css_path, ".screen { font-family: Primary, Fallback, sans-serif; }\n.bold { font-weight: 700; }")
      declaration_path = File.join(project, PortableProject::FILE_NAME)
      declaration = JSON.parse(File.read(declaration_path)).as_h
      declaration["fonts"] = JSON.parse(<<-JSON)
        {"Primary":"public/station-sans.woff2","Fallback":"public/station-sans.woff2"}
        JSON
      File.write(declaration_path, declaration.to_json)
      portable_diagnostic(project, "lib/styles/base.css:2: portable component 'PortableScreen': font stack 'Primary, Fallback, sans-serif' has no declared face for weight 700")

      # Primary lacks 700. Resolve the exact-weight fallback for Latin, then
      # the following face for Omega, using the coverage declared by the files.
      declaration["fonts"] = JSON.parse(<<-JSON)
        {
          "Primary":"public/station-sans.woff2",
          "Fallback":{"700":{"file":"public/station-sans-bold.woff2","license":"public/OFL.txt"}},
          "Symbols":{"700":{"file":"public/station-symbols-bold.woff2","license":"public/OFL.txt"}},
          "Unused":{"400":{"file":"public/station-sans-bold.woff2"}}
        }
        JSON
      File.write(declaration_path, declaration.to_json)
      File.write(css_path, File.read(css_path).sub("Primary, Fallback, sans-serif", "Primary, Fallback, Symbols, sans-serif"))
      dom = compile_portable_spec(project, RenderTarget::Dom)
      desktop = compile_portable_spec(project, RenderTarget::Desktop)
      scene = JSON.parse(File.read(File.join(desktop, "scene.json")))
      stack = scene["font_stacks"]["Primary, Fallback, Symbols, sans-serif"]
      stack["400"]["faces"].as_a.size.should eq(1)
      stack["700"]["faces"].as_a.size.should eq(2)
      resources = JSON.parse(File.read(File.join(dom, "mochi-manifest.json")))["resources"].as_h
      resources.values.count { |resource| resource["kind"].as_s == "font" }.should eq(3)
      resources.values.count { |resource| resource["kind"].as_s == "font-license" }.should eq(1)
      stylesheet = resources.values.find! { |resource| resource["kind"].as_s == "document-style" }["file"].as_s
      File.read(File.join(dom, stylesheet)).should contain("unicode-range:U+3a9")

      declaration["fonts"].as_h["Fallback"] = JSON.parse(%q({"700":{"file":"public/station-sans.woff2"}}))
      File.write(declaration_path, declaration.to_json)
      portable_diagnostic(project, "mochi-portable.json: public/station-sans.woff2 declares weight 700, but the face reports 400")
    end
  end
end
