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
  child_row = EachRowTemplate.new(
    1,
    "item[:children]",
    "child",
    "ci",
    nil,
    "<b>{child}</b>",
    [EachRowBindingDescriptor.new(0, "text", nil, "child")],
    [] of EachRowEventDescriptor,
    [] of EachRowTemplate,
    [EachRowScope.new("item", "index"), EachRowScope.new("child", "ci")]
  )
  each_row = EachRowTemplate.new(
    0,
    "@items",
    "item",
    "index",
    nil,
    "<span>{item[:name]}</span><!--mochi-each-1-->",
    [
      EachRowBindingDescriptor.new(0, "text", nil, "item[:name]"),
      EachRowBindingDescriptor.new(1, "attr", "hidden", "item[:hidden]", nil, false, "boolean"),
    ],
    [] of EachRowEventDescriptor,
    [child_row],
    [EachRowScope.new("item", "index")],
    %Q{item[:id]},
    TemplateSourceSpan.new("lib/my_counter.rb", 20, 7, 20, 13, 6)
  )
  bindings = [
    BindingDescriptor.new(
      0,
      [0, 0],
      "text",
      "__mochi_bind_0",
      nil,
      "Count: {count}",
      "@count",
      [] of ConditionalBranchDescriptor,
      nil,
      8,
      21,
      [] of String,
      TemplateSourceSpan.new("lib/my_counter.rb", 12, 9, 12, 22, 13)
    ),
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
    BindingDescriptor.new(
      3,
      [1],
      "expr",
      "__mochi_bind_3",
      nil,
      "@query",
      "@query"
    ),
    BindingDescriptor.new(
      4,
      [3],
      "each",
      "__mochi_each_0_rows",
      "item,index",
      "<span>{item[:name]}</span>",
      nil,
      [] of ConditionalBranchDescriptor,
      nil,
      nil,
      nil,
      [] of String,
      nil,
      each_row
    ),
    BindingDescriptor.new(
      5,
      [4],
      "attr",
      "__mochi_bind_5",
      "disabled",
      "{@disabled}",
      "@disabled",
      attr_kind: "boolean"
    ),
  ]
  events = [
    EventDescriptor.new([1], "click", "increment", [
      EventArgumentDescriptor.literal_string("tr_9f2a"),
      EventArgumentDescriptor.literal_number("1"),
      EventArgumentDescriptor.event,
    ]),
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
  manifest.source_file = "lib/my_counter.rb"
  manifest.source_line = 7
  manifest.method_lines = {"initialize" => 14, "increment" => 18}
  manifest.props = [
    PropDescriptor.new("label", "string", required: true, source_file: "lib/my_counter.rb", source_line: 8),
    PropDescriptor.new("count", "integer", default: true, default_code: "0", source_file: "lib/my_counter.rb", source_line: 9),
  ]
  manifest.emits = [
    ComponentEventDescriptor.new(
      "select",
      [EventPayloadDescriptor.new("id", "integer")],
      "lib/my_counter.rb",
      10
    ),
  ]

  MochiComponent.new(
    File.join(dir, "my_counter.rb"),
    "MyCounter",
    [] of String,
    ruby_source,
    manifest,
    manifest.html_template,
    manifest.css,
    7,
    "lib/my_counter.rb",
    10
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
      component_json["source"].as_h["file"].as_s.should eq("lib/my_counter.rb")
      component_json["source"].as_h["line"].as_i.should eq(7)
      component_json["methods"].as_h["initialize"].as_i.should eq(14)
      component_json["methods"].as_h["increment"].as_i.should eq(18)

      props = component_json["props"].as_a
      props.size.should eq(2)
      props[0].as_h["name"].as_s.should eq("label")
      props[0].as_h["type"].as_s.should eq("string")
      props[0].as_h["required"].as_bool.should be_true
      props[0].as_h["source"].as_h["line"].as_i.should eq(8)
      props[0].as_h.has_key?("default_code").should be_false
      props[1].as_h["name"].as_s.should eq("count")
      props[1].as_h["default"].as_bool.should be_true
      props[1].as_h["source"].as_h["file"].as_s.should eq("lib/my_counter.rb")

      emits = component_json["emits"].as_a
      emits.size.should eq(1)
      emits[0].as_h["name"].as_s.should eq("select")
      emits[0].as_h["payload"].as_a[0].as_h["name"].as_s.should eq("id")
      emits[0].as_h["payload"].as_a[0].as_h["type"].as_s.should eq("integer")
      emits[0].as_h["source"].as_h["line"].as_i.should eq(10)

      bindings = component_json["bindings"].as_a
      bindings.first.as_h["id"].as_i.should eq(0)
      bindings.first.as_h["path"].as_a.map(&.as_i).should eq([0, 0])
      bindings.first.as_h["getter_sym"].as_s.should eq("__mochi_bind_0")
      bindings.first.as_h["template_start"].as_i.should eq(8)
      bindings.first.as_h["template_end"].as_i.should eq(21)
      source = bindings.first.as_h["source"].as_h
      source["file"].as_s.should eq("lib/my_counter.rb")
      source["line"].as_i.should eq(12)
      source["column"].as_i.should eq(9)

      cond = bindings.find { |entry| entry.as_h["kind"].as_s == "cond" }.not_nil!
      cond.as_h["getter_sym"].as_s.should eq("__mochi_bind_1")
      branches = cond.as_h["branches"].as_a
      branches.size.should eq(1)
      branches.first.as_h["html_template"].as_s.should eq("<p>High</p>")
      branch_bindings = branches.first.as_h["bindings"].as_a
      branch_bindings.first.as_h["id"].as_i.should eq(2)
      branch_bindings.first.as_h["getter_sym"].as_s.should eq("__mochi_bind_2")

      expr = bindings.find { |entry| entry.as_h["kind"].as_s == "expr" }.not_nil!
      expr.as_h["getter_expr"].as_s.should eq("@query")
      attr = bindings.find { |entry| entry.as_h["kind"].as_s == "attr" }.not_nil!
      attr.as_h["attr_name"].as_s.should eq("disabled")
      attr.as_h["attr_kind"].as_s.should eq("boolean")

      each = bindings.find { |entry| entry.as_h["kind"].as_s == "each" }.not_nil!
      each.as_h["getter_sym"].as_s.should eq("__mochi_each_0_rows")
      rows = each.as_h["each_rows"].as_h
      rows["id"].as_i.should eq(0)
      rows["keyed"].as_bool.should be_true
      row_source = rows["source"].as_h
      row_source["file"].as_s.should eq("lib/my_counter.rb")
      row_source["line"].as_i.should eq(20)
      rows["bindings"].as_a.first.as_h["slot"].as_i.should eq(0)
      row_attr = rows["bindings"].as_a.find { |entry| entry.as_h["attr_name"].as_s? == "hidden" }.not_nil!
      row_attr.as_h["attr_kind"].as_s.should eq("boolean")
      rows["children"].as_a.size.should eq(1)
      child = rows["children"].as_a.first.as_h
      child["id"].as_i.should eq(1)
      child["template"].as_s.should eq("<b>{child}</b>")
      child.has_key?("each_rows").should be_false
      child.has_key?("keyed").should be_false

      events = component_json["events"].as_a
      events.first.as_h["event"].as_s.should eq("click")
      events.first.as_h["method_sym"].as_s.should eq("increment")
      args = events.first.as_h["args"].as_a
      args.size.should eq(3)
      args[0].as_h["kind"].as_s.should eq("literal")
      args[0].as_h["literal_type"].as_s.should eq("string")
      args[0].as_h["value"].as_s.should eq("tr_9f2a")
      args[1].as_h["literal_type"].as_s.should eq("number")
      args[1].as_h["value"].as_s.should eq("1")
      args[2].as_h["kind"].as_s.should eq("event")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "maps mrbc tempfile lines back to the original Ruby file" do
    dir = File.join(Dir.tempdir, "mochi_mrbc_error_spec_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(dir)

    begin
      mrbc = File.join(dir, "failing_mrbc")
      script = <<-SH
#!/bin/sh
input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2;;
    *) input="$1"; shift;;
  esac
done
echo "$input:5: syntax error, unexpected end" >&2
exit 1
SH
      File.write(mrbc, script)
      File.chmod(mrbc, File::Permissions.new(0o755))

      component = build_mrbc_fixture(dir)
      compiler = MrbcCompiler.new(mrbc_path: mrbc)
      error = expect_raises(Exception) do
        compiler.compile([component], File.join(dir, "out"))
      end
      message = error.message.to_s
      message.should contain("lib/my_counter.rb:14")
      message.should_not contain("mochi-my-counter")
      message.should contain("syntax error")
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

    it "walks int64, float, and bigint pool entries without losing alignment" do
      dir = File.join(Dir.tempdir, "mochi_numeric_mrbc_spec_#{Random.rand(1_000_000)}")
      Dir.mkdir_p(dir)

      begin
        source_path = File.join(dir, "numeric.rb")
        bytecode_path = File.join(dir, "numeric.mrb")
        File.write(source_path, <<-RUBY)
class NumericPool
  def values
    [2147483648, 9007199254740993, 9223372036854775807, -9223372036854775808, 0.5]
  end
end
RUBY

        output = IO::Memory.new
        status = Process.run(real_mrbc, ["-o", bytecode_path, source_path], output: output, error: output)
        status.success?.should be_true
        RiteVerifier.verify!(File.read(bytecode_path).to_slice, "numeric.rb")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
