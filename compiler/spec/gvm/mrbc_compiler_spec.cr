require "spec"
require "json"
require "file_utils"
require "../../src/gvm/mrbc_compiler"

private def build_mrbc_fixture(dir : String)
  ruby_source = <<-RUBY
class MyCounter
  extend T::Sig

  @tag_name = "my-counter"

  sig { void }
  def initialize
    @count = T.let(0, Integer)
  end

  def __mochi_bind_0; @count; end
end
RUBY

  branch = ConditionalBranchDescriptor.new(
    "<p>High</p>",
    [
      BindingDescriptor.new(2, [0, 0], "text", "__mochi_bind_2", nil, "High {@count}", "@count"),
    ],
    [] of EventDescriptor
  )
  bindings = [
    BindingDescriptor.new(0, [0, 0], "text", "__mochi_bind_0", nil, "Count: {count}", "@count"),
    BindingDescriptor.new(
      1,
      [2],
      "cond",
      "__mochi_bind_1",
      nil,
      "<p>High</p>",
      "__mochi_cond_0",
      [branch]
    ),
  ]
  events = [
    EventDescriptor.new([1], "click", "increment"),
  ]
  manifest = ComponentManifest.new(
    "my-counter",
    "MyCounter",
    "my-counter.chi",
    %Q{<h1>Count: {count}</h1><button data-mochi-click="increment">+</button>},
    "h1 { color: red; }",
    bindings,
    events
  )

  MochiComponent.new(
    File.join(dir, "my_counter.rb"),
    "MyCounter",
    [] of String,
    ruby_source,
    manifest,
    manifest.html_template,
    manifest.css
  )
end

private def write_fake_mrbc(path : String, log_path : String)
  script = <<-SH
#!/bin/sh
out=""
input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    *) input="$1"; shift;;
  esac
done
cp "$input" "#{log_path}"
{ printf 'RITE0400'; printf '\\000\\000'; printf 'RUBYBYTECODE'; } > "$out"
SH

  File.write(path, script)
  File.chmod(path, File::Permissions.new(0o755))
end

describe MrbcCompiler do
  it "strips Sorbet, emits .chi files, copies assets, and writes the manifest" do
    dir = File.join(Dir.tempdir, "mochi_mrbc_spec_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(dir)

    begin
      mrbc = File.join(dir, "fake_mrbc")
      wasm = File.join(dir, "source.wasm")
      js = File.join(dir, "source.js")
      loader = File.join(dir, "mochi-loader.js")
      stripped_source_path = File.join(dir, "stripped.rb")
      output = File.join(dir, "out")

      write_fake_mrbc(mrbc, stripped_source_path)
      File.write(wasm, "WASM")
      File.write(js, "JS")
      File.write(loader, "LOADER")

      component = build_mrbc_fixture(dir)
      compiler = MrbcCompiler.new(mrbc_path: mrbc, wasm_source: wasm, loader_source: loader)
      compiler.compile([component], output)

      chi_path = File.join(output, "components", "my-counter.chi")
      File.read(chi_path).should eq("RUBYBYTECODE")
      File.read(File.join(output, "mochi-gvm.wasm")).should eq("WASM")
      File.read(File.join(output, "mochi-gvm.js")).should eq("JS")
      File.read(File.join(output, "mochi-loader.js")).should eq("LOADER")
      compiler.chi_paths.should eq([chi_path])

      stripped_source = File.read(stripped_source_path)
      stripped_source.should_not contain("extend T::Sig")
      stripped_source.should_not contain("sig {")
      stripped_source.should_not contain("@tag_name")
      stripped_source.should contain("@count = 0")

      json = JSON.parse(File.read(File.join(output, "mochi-manifest.json")))
      json["wasm_file"].as_s.should eq("mochi-gvm.wasm")
      json["js_file"].as_s.should eq("mochi-gvm.js")
      json["loader_file"].as_s.should eq("mochi-loader.js")

      components = json["components"].as_a
      components.size.should eq(1)
      component_json = components.first.as_h
      component_json["tag_name"].as_s.should eq("my-counter")
      component_json["class_name"].as_s.should eq("MyCounter")
      component_json["chi_file"].as_s.should eq("my-counter.chi")
      component_json["html_template"].as_s.should contain("Count: {count}")
      component_json["css"].as_s.should eq("h1 { color: red; }")

      bindings = component_json["bindings"].as_a
      bindings.first.as_h["id"].as_i.should eq(0)
      bindings.first.as_h["path"].as_a.map(&.as_i).should eq([0, 0])
      bindings.first.as_h["getter_sym"].as_s.should eq("__mochi_bind_0")

      cond = bindings.find { |entry| entry.as_h["kind"].as_s == "cond" }.not_nil!
      cond.as_h["getter_sym"].as_s.should eq("__mochi_bind_1")
      branches = cond.as_h["branches"].as_a
      branches.size.should eq(1)
      branches.first.as_h["html_template"].as_s.should eq("<p>High</p>")
      branch_bindings = branches.first.as_h["bindings"].as_a
      branch_bindings.first.as_h["id"].as_i.should eq(2)
      branch_bindings.first.as_h["getter_sym"].as_s.should eq("__mochi_bind_2")

      events = component_json["events"].as_a
      events.first.as_h["event"].as_s.should eq("click")
      events.first.as_h["method_sym"].as_s.should eq("increment")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  if real_mrbc = MrbcCompiler.find_mrbc
    it "emits valid mrbc bytecode under 1 KB" do
      dir = File.join(Dir.tempdir, "mochi_real_mrbc_spec_#{Random.rand(1_000_000)}")
      Dir.mkdir_p(dir)

      begin
        output = File.join(dir, "out")
        component = build_mrbc_fixture(dir)
        compiler = MrbcCompiler.new(
          mrbc_path: real_mrbc,
          wasm_source: File.join(dir, "missing.wasm"),
          js_source: File.join(dir, "missing-gvm.js"),
          loader_source: File.join(dir, "missing.js")
        )
        compiler.compile([component], output)

        chi_path = File.join(output, "components", "my-counter.chi")
        File.exists?(chi_path).should be_true
        File.size(chi_path).should be < 1024
        File.read(chi_path).includes?("MATZ").should be_true
        compiler.warnings.size.should eq(3)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
