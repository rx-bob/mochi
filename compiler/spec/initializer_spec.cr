require "spec"
require "file_utils"
require "random"
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
      lint_config.should contain("metrics/method-length:")
      lint_config.should contain("max: 60")
      index.should contain("mochi-loader.js")
      index.should contain(%(data-mochi-manifest="./mochi-manifest.json"))
      index.should contain(%(<base href="/">))
      index.should contain("<my-counter></my-counter>")
      index.should_not contain("https://github.com/")
      index.should_not contain("Opal")
      readme.should contain("test/")
      readme.should contain("task check")
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
