require "spec"
require "file_utils"
require "random"
require "yaml"
require "../src/initializer"
require "../src/tooling/lint_runner"

describe Initializer do
  it "scaffolds a GVM app with a Ruby behavior test command and example" do
    root = File.join(Dir.tempdir, "mochi_initializer_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)

    begin
      Dir.cd(root) do
        Initializer.new("sample")
      end

      project = File.join(root, "sample")
      taskfile = File.read(File.join(project, "Taskfile.yml"))
      lint_config = File.read(File.join(project, ".mochi-lint.yml"))
      index = File.read(File.join(project, "index.html"))
      readme = File.read(File.join(project, "README.md"))
      example = File.read(File.join(project, "test", "counter_test.rb"))

      taskfile.should contain("mochi test -i")
      taskfile.should contain("mochi lint -i")
      taskfile.should contain("task: lint")
      taskfile.should contain("task: test")
      taskfile.should contain("mochi dev --config")
      taskfile.should contain("mochi -i \"./\" -o \"./build\"")
      lint_config.should contain("version: 1")
      lint_config.should contain(%(include:\n  - "lib/**/*.rb"))
      lint_config.should contain("correctness/method-missing: error")
      lint_config.should contain("metrics/method-length:")
      lint_config.should contain("max: 60")
      lint_config.should contain("metrics/html-method-length:")
      lint_config.should contain("max: 50")
      lint_config.should contain("metrics/line-length:")
      lint_config.should contain("max: 120")
      lint_config.should contain("metrics/class-variables:")
      lint_config.should contain("max: 10")
      lint_config.should contain("structure/package-files:")
      lint_config.should contain("max: 10")
      lint_config.should contain("style/css-declaration-lines: warning")
      lint_config.should contain("style/template-block-lines: warning")
      lint_config.should contain("style/template-element-indent: warning")
      index.should contain("mochi-loader.js")
      index.should contain(%(data-mochi-manifest="./mochi-manifest.json"))
      index.should contain(%(<base href="/">))
      index.should contain("<my-counter></my-counter>")
      index.should_not contain("https://github.com/")
      index.should_not contain("Opal")
      readme.should contain("test/")
      readme.should contain("task check")
      readme.should contain("task lint")
      readme.should contain("mochi lint -i .")
      readme.should contain("do not run lint")
      readme.should contain("references/LINT_CONTRACT.md")
      readme.should contain("assert_text")
      readme.should contain(".chi")
      readme.should contain(">>>")
      readme.should contain("npx playwright install")
      readme.should contain("No app-authored JavaScript is needed")
      example.should contain("Mochi::Test.test")
      example.should contain("assert_text")

      output = IO::Memory.new
      status = LintRunner.new.run(["-i", project], output: output, error: output)
      status.should eq 0
      output.to_s.should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "wires generated task check to lint before test" do
    root = File.join(Dir.tempdir, "mochi_initializer_task_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)

    begin
      Dir.cd(root) do
        Initializer.new("sample")
      end

      project = File.join(root, "sample")
      taskfile = YAML.parse(File.read(File.join(project, "Taskfile.yml")))
      tasks = taskfile["tasks"]

      tasks["lint"]["cmds"][0].as_s.should eq %(mochi lint -i "./")
      tasks["test"]["cmds"][0].as_s.should eq %(mochi test -i "./")

      check = tasks["check"]["cmds"].as_a
      check.map { |entry| entry["task"].as_s }.should eq ["lint", "test"]
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "fails the generated check gate for a lint violation without changing build" do
    root = File.join(Dir.tempdir, "mochi_initializer_lint_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)

    begin
      Dir.cd(root) do
        Initializer.new("sample")
      end

      project = File.join(root, "sample")
      File.write(
        File.join(project, "lib", "ComplexityProbe.rb"),
        "class ComplexityProbe\n  def long_method\n#{"value = 1\n" * 62}  end\nend\n",
      )

      output = IO::Memory.new
      status = LintRunner.new.run(["-i", project], output: output, error: output)
      status.should eq 1
      output.to_s.should contain("metrics/method-length")
      output.to_s.should contain("ComplexityProbe.rb")

      taskfile = File.read(File.join(project, "Taskfile.yml"))
      check_commands = taskfile.split("check:", 2)[1]
      check_commands.index("task: lint").not_nil!.should be < check_commands.index("task: test").not_nil!
      taskfile.split("build:", 2)[1].split("lint:", 2)[0].should_not contain("mochi lint")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
