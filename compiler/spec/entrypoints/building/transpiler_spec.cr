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
      each_binding.template_text.not_nil!.should contain("data-mochi-click=\"toggle_pause\"")
      component.manifest.event_names.should contain("click")
      component.ruby_code.should_not contain("__mochi_each_")
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
end
