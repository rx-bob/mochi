require "spec"
require "file_utils"
require "json"
require "../../src/entrypoints/building/transpiler"
require "../../src/gvm/mrbc_compiler"
require "../../src/webcomponents/style_composer"
require "../../src/webcomponents/resource_manifest"

def print_cmp_start_separator(tag_name : String, i : Int32)
end

def print_cmp_end_seperator(tag_name : String, i : Int32)
end

private def make_style_project : String
  root = File.join(Dir.tempdir, "mochi_style_spec_#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(File.join(root, "styles"))
  File.write(File.join(root, "styles", "reset.css"), <<-CSS)
*, *::before, *::after { box-sizing: border-box; }
CSS
  File.write(File.join(root, "styles", "controls.css"), <<-CSS)
@import "reset.css";
.btn { display: inline-flex; padding: 7px 11px; }
CSS
  root
end

private def transpile_style_component(root : String, name : String, tag : String, background : String) : MochiComponent
  path = File.join(root, "#{name}.rb")
  File.write(path, <<-RUBY)
class #{name}
  @tag_name = "#{tag}"

  def html
    %Q{<button class="btn">Press</button>}
  end

  def css
    %Q{
      @import "styles/controls.css";
      :host { display: block; }
      .btn { background: #{background}; }
    }
  end
end
RUBY
  component = Compiler.new.transpile_component(File.read(path), 1, path)
  component.should_not be_nil
  component.not_nil!
end

describe StyleComposer do
  it "shares one style resource across components and keeps local overrides last" do
    root = make_style_project
    begin
      alpha = transpile_style_component(root, "AlphaCard", "alpha-card", "red")
      beta = transpile_style_component(root, "BetaCard", "beta-card", "blue")

      alpha.manifest.style_resource_ids.size.should eq(2)
      beta.manifest.style_resource_ids.should eq(alpha.manifest.style_resource_ids)
      alpha.manifest.style_resources[0].text.not_nil!.should contain("box-sizing")
      alpha.manifest.style_resources[1].text.not_nil!.should contain(".btn")
      alpha.manifest.css.should contain("background: red")
      beta.manifest.css.should contain("background: blue")
      alpha.manifest.css.should_not contain("@import")

      if mrbc = MrbcCompiler.find_mrbc
        output = File.join(root, "out")
        compiler = MrbcCompiler.new(mrbc_path: mrbc)
        compiler.compile([alpha, beta], output)

        manifest = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
        resources = manifest["resources"].as_h
        resources.size.should eq(2)
        resources.each do |id, resource|
          resource.as_h.has_key?("text").should be_false
          file = resource.as_h["file"].as_s
          File.exists?(File.join(output, file)).should be_true
        end
        alpha_index = manifest["components"].as_a.find { |entry| entry["tag_name"] == "alpha-card" }.not_nil!
        beta_index = manifest["components"].as_a.find { |entry| entry["tag_name"] == "beta-card" }.not_nil!
        alpha_entry = JSON.parse(File.read(File.join(output, alpha_index["descriptor"].as_s)))
        beta_entry = JSON.parse(File.read(File.join(output, beta_index["descriptor"].as_s)))
        alpha_entry["style_resources"].should eq(beta_entry["style_resources"])
        alpha_entry["style_resources"].as_a.size.should eq(2)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "finds imports after multibyte comments without slicing characters" do
    root = make_style_project
    begin
      path = File.join(root, "Multibyte.rb")
      File.write(path, <<-RUBY)
class Multibyte
  @tag_name = "multibyte"

  def css
    %Q{/* café */ @import "styles/reset.css"; :host { display: block; } }
  end
end
RUBY
      composition = StyleComposer.new("Multibyte", path, "lib/Multibyte.rb")
        .compose("/* café */ @import \"styles/reset.css\"; :host { display: block; }")
      composition.style_resource_ids.size.should eq(1)
      composition.css.should contain("display: block")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "names the component and fragment when an import is missing" do
    root = make_style_project
    begin
      path = File.join(root, "MissingImport.rb")
      File.write(path, <<-RUBY)
class MissingImport
  @tag_name = "missing-import"

  def html
    %Q{<div>missing</div>}
  end

  def css
    %Q{ @import "styles/nope.css"; :host { display: block; } }
  end
end
RUBY

      ex = expect_raises(Exception, /MissingImport.*styles\/nope\.css/) do
        Compiler.new.transpile_component(File.read(path), 1, path)
      end
      ex.message.not_nil!.should contain("was not found")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "names the fragment and component when a shared stylesheet does not parse" do
    root = make_style_project
    begin
      File.write(File.join(root, "styles", "broken.css"), ".btn { color: red;")
      path = File.join(root, "BrokenImport.rb")
      File.write(path, <<-RUBY)
class BrokenImport
  @tag_name = "broken-import"

  def html
    %Q{<div>broken</div>}
  end

  def css
    %Q{ @import "styles/broken.css"; }
  end
end
RUBY

      ex = expect_raises(Exception, /BrokenImport.*broken\.css.*unclosed block/) do
        Compiler.new.transpile_component(File.read(path), 1, path)
      end
      ex.message.not_nil!.should contain("CSS fragment")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects interpolation rather than treating it as runtime CSS" do
    root = make_style_project
    begin
      path = File.join(root, "InterpolatedCss.rb")
      File.write(path, <<-RUBY)
class InterpolatedCss
  @tag_name = "interpolated-css"
  @color = "red"

  def html
    %Q{<div>bad</div>}
  end

  def css
    %Q{ .box { color: \#{@color}; } }
  end
end
RUBY

      expect_raises(Exception, /InterpolatedCss.*interpolation/) do
        Compiler.new.transpile_component(File.read(path), 1, path)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe IconAssetCollector do
  it "emits only referenced SVG assets and copies them into the package" do
    root = File.join(Dir.tempdir, "mochi_icon_spec_#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(root, "icons"))
    File.write(File.join(root, "icons", "home.svg"), %Q{<svg id="mochi-icon" viewBox="0 0 24 24"><path d="M3 12h18"/></svg>})
    File.write(File.join(root, "icons", "unused.svg"), %Q{<svg id="mochi-icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/></svg>})

    path = File.join(root, "IconCard.rb")
    File.write(path, <<-RUBY)
class IconCard
  @tag_name = "icon-card"

  def html
    %Q{<span>{Mochi.raw(MochiIcons.icon("home"))}</span>}
  end
end
RUBY

    begin
      component = Compiler.new.transpile_component(File.read(path), 1, path).not_nil!
      icons = IconAssetCollector.new(File.join(root, "icons")).collect([path])
      icons.map(&.id).should eq(["icon:home"])
      icons.first.output_file.should eq("mochi-icons/home.svg")

      if mrbc = MrbcCompiler.find_mrbc
        output = File.join(root, "out")
        FileUtils.mkdir_p(File.join(output, "mochi-icons"))
        File.write(File.join(output, "mochi-icons", "unused.svg"), "stale")
        MrbcCompiler.new(mrbc_path: mrbc).compile([component], output, resources: icons)

        File.exists?(File.join(output, "mochi-icons", "home.svg")).should be_true
        File.exists?(File.join(output, "mochi-icons", "unused.svg")).should be_false
        manifest = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
        manifest["resources"].as_h.keys.should eq(["icon:home"])
        manifest["resources"]["icon:home"]["file"].should eq("mochi-icons/home.svg")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reports the component source when a requested icon has no asset" do
    root = File.join(Dir.tempdir, "mochi_icon_missing_#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(root, "icons"))
    path = File.join(root, "MissingIcon.rb")
    File.write(path, <<-RUBY)
class MissingIcon
  @tag_name = "missing-icon"

  def html
    %Q{<span>{Mochi.raw(MochiIcons.icon("ghost"))}</span>}
  end
end
RUBY

    begin
      expect_raises(Exception, /MissingIcon\.rb:\d+.*ghost/) do
        IconAssetCollector.new(File.join(root, "icons")).collect([path])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
