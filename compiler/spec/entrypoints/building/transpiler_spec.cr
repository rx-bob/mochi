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
  end
end
