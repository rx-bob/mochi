require "spec"
require "file_utils"
require "json"
require "random"
require "../../src/tooling/lint_runner"

module LintCliSpecSupport
  extend self

  VALID_COMPONENT = <<-RUBY
    class GoodWidget
      @tag_name = "good-widget"

      def html
        %Q{<p>ok</p>}
      end
    end
    RUBY

  INVALID_COMPONENT = <<-RUBY
    class BrokenWidget
      @tag_name = "broken-widget"

      def html
        %Q{<p>broken</p>}
      end
    RUBY

  def with_project(prefix = "mochi_lint_cli", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(File.join(root, "lib"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write_source(root : String, relative_path : String, source : String) : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def run_lint(root : String, args : Array(String) = [] of String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = LintRunner.new.run(args, stdout, stderr, root)
    {status, stdout.to_s, stderr.to_s}
  end
end

describe LintRunner do
  it "accepts a valid Ruby component without findings or output" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""
      File.exists?(File.join(root, "build")).should be_false
    end
  end

  it "reports invalid Ruby with a source-located syntax diagnostic and exit 1" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/BrokenWidget.rb", LintCliSpecSupport::INVALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["-i", root])

      status.should eq 1
      stderr.should eq ""
      stdout.lines.first.should match(/\Alib\/BrokenWidget\.rb:\d+:\d+: error ruby\/syntax: /)
      stdout.should match(/error ruby\/syntax: (Ruby syntax error|missing 'end')/)
    end
  end

  it "reports one diagnostic for a top-level invalid subtree" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/BrokenCall.rb", <<-RUBY)
        class FirstBroken
          def render
            compute(
          end
        end

        class SecondBroken
          def render
            other(
          end
        end
        RUBY

      status, stdout, _stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 1
      stdout.lines.size.should eq 1
      stdout.should contain("error ruby/syntax:")
    end
  end

  it "reports a missing token without cascading into later error nodes" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/Recoverable.rb", <<-RUBY)
        class First
          def ok
          end
        end

        class Broken
          def broken(
          end
        end

        class Last
          def ok
          end
        end
        RUBY

      status, stdout, _stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 1
      stdout.should contain("missing ')'")
      stdout.lines.size.should eq 1
    end
  end

  it "emits parseable compact JSON without a startup banner" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/BrokenWidget.rb", LintCliSpecSupport::INVALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--format=json"])

      status.should eq 1
      stderr.should eq ""
      stdout.should_not contain("Mochi v0.3")
      parsed = JSON.parse(stdout).as_h
      parsed["schema_version"].as_i.should eq 1
      diagnostics = parsed["diagnostics"].as_a
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first.as_h
      diagnostic["path"].as_s.should eq "lib/BrokenWidget.rb"
      diagnostic["severity"].as_s.should eq "error"
      diagnostic["rule"].as_s.should eq "ruby/syntax"
      diagnostic["line"].as_i.should be >= 1
      diagnostic["column"].as_i.should be >= 1
      diagnostic["start_byte"].as_i.should be >= 0
    end
  end

  it "emits an empty JSON diagnostics array for a clean project" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--format", "json"])

      status.should eq 0
      stderr.should eq ""
      parsed = JSON.parse(stdout).as_h
      parsed["schema_version"].as_i.should eq 1
      parsed["diagnostics"].as_a.should be_empty
    end
  end

  it "lints the current project when no -i is supplied" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""
    end
  end

  it "finds a config from a nested working directory and reports the same paths as explicit config" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/BrokenWidget.rb", LintCliSpecSupport::INVALID_COMPONENT)
      File.write(File.join(root, ".mochi-lint.yml"), "version: 1\n")
      nested = File.join(root, "lib", "nested")
      Dir.mkdir_p(nested)

      discovered_status, discovered_output, discovered_stderr = LintCliSpecSupport.run_lint(nested)
      explicit_status, explicit_output, explicit_stderr = LintCliSpecSupport.run_lint(
        nested,
        ["-i", root, "--config", File.join(root, ".mochi-lint.yml")],
      )

      discovered_status.should eq 1
      explicit_status.should eq 1
      discovered_stderr.should eq ""
      explicit_stderr.should eq ""
      discovered_output.should eq explicit_output
      discovered_output.lines.first.should start_with("lib/BrokenWidget.rb:")
    end
  end

  it "honors include and exclude lists from the config" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "src/keep.rb", LintCliSpecSupport::VALID_COMPONENT)
      LintCliSpecSupport.write_source(root, "src/drop.rb", LintCliSpecSupport::INVALID_COMPONENT)
      LintCliSpecSupport.write_source(root, "lib/ignored.rb", LintCliSpecSupport::INVALID_COMPONENT)
      File.write(File.join(root, ".mochi-lint.yml"), <<-YAML)
        version: 1
        include: ["src/**/*.rb"]
        exclude: ["src/drop.rb"]
        YAML

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""
    end
  end

  it "blocks findings at both warning and error severity" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          @tag_name = "widget"

          def html
            %Q{<button onclick="{missing}">Go</button>}
          end
        end
        RUBY
      config = <<-YAML
        version: 1
        include:
          - "lib/**/*.rb"
        rules:
          correctness/unknown-handler: warning
        YAML
      LintCliSpecSupport.write_source(root, ".mochi-lint.yml", config)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)
      status.should eq 1
      stdout.should contain "warning correctness/unknown-handler"
      stderr.should be_empty

      LintCliSpecSupport.write_source(root, ".mochi-lint.yml", config.sub("warning", "error"))
      status, stdout, stderr = LintCliSpecSupport.run_lint(root)
      status.should eq 1
      stdout.should contain "error correctness/unknown-handler"
      stderr.should be_empty
    end
  end

  it "accepts the long input form and rejects a symlinked project root" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--input", root])
      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""

      target = File.join(root, "target")
      Dir.mkdir_p(target)
      link = File.join(root, "linked-project")
      File.symlink(target, link)
      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["-i", link])
      status.should eq 2
      stdout.should eq ""
      stderr.should contain "project directory cannot be a symlink"
    end
  end

  it "does not require compiler runtime artifacts or browser tools" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)
      names = %w[MRBC MOCHI_GVM_WASM MOCHI_GVM_JS MOCHI_LOADER MOCHI_FORMAT_HOST PATH]
      previous = names.to_h { |name| {name, ENV[name]?} }
      begin
        names.each { |name| ENV[name] = "/nonexistent/#{name.downcase}" }
        status, stdout, stderr = LintCliSpecSupport.run_lint(root)
        status.should eq 0
        stdout.should eq ""
        stderr.should eq ""
      ensure
        previous.each do |name, value|
          if value
            ENV[name] = value
          else
            ENV.delete(name)
          end
        end
      end
    end
  end

  it "reports invalid config at its source location with exit 2" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)
      config_path = File.join(root, ".mochi-lint.yml")
      File.write(config_path, <<-YAML)
        version: 1
        rules:
          unknown/rule: warning
        YAML

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 2
      stdout.should eq ""
      stderr.should contain("mochi lint:")
      stderr.should contain(File.realpath(config_path))
      stderr.should contain("unknown rule 'unknown/rule'")
      stderr.should match(/:\d+:\d+: unknown rule/)
    end
  end

  it "sorts independent file diagnostics deterministically" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/z_last.rb", LintCliSpecSupport::INVALID_COMPONENT)
      LintCliSpecSupport.write_source(root, "lib/a_first.rb", LintCliSpecSupport::INVALID_COMPONENT)

      first_status, first_output, _first_stderr = LintCliSpecSupport.run_lint(root)
      second_status, second_output, _second_stderr = LintCliSpecSupport.run_lint(root)

      first_status.should eq 1
      second_status.should eq 1
      second_output.should eq first_output
      first_output.lines.first.should start_with("lib/a_first.rb:")
      first_output.should contain("lib/z_last.rb:")
    end
  end

  it "reports independent valid files when another source is invalid" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/BrokenWidget.rb", LintCliSpecSupport::INVALID_COMPONENT)
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)

      status, stdout, _stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 1
      stdout.lines.size.should eq 1
      stdout.should contain("lib/BrokenWidget.rb:")
      stdout.should_not contain("lib/GoodWidget.rb:")
    end
  end

  it "accepts an explicit config path but rejects a missing one" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/GoodWidget.rb", LintCliSpecSupport::VALID_COMPONENT)
      File.write(File.join(root, ".mochi-lint.yml"), "version: 1\n")

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--config", ".mochi-lint.yml"])
      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""

      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--config", "missing.yml"])
      status.should eq 2
      stdout.should eq ""
      stderr.should contain("config file not found")
    end
  end

  it "prints lint help without requiring a project" do
    LintCliSpecSupport.with_project do |root|
      status, stdout, stderr = LintCliSpecSupport.run_lint(root, ["--help"])

      status.should eq 0
      stdout.should contain("Usage: mochi lint")
      stdout.should contain("--format=FORMAT")
      stderr.should eq ""
    end
  end

  it "uses exit 2 for invocation and input failures" do
    LintCliSpecSupport.with_project do |root|
      cases = [
        {["--bogus"], "unknown option"},
        {["--format", "yaml"], "unsupported format"},
        {["--format", "text", "--format", "json"], "conflicting format"},
        {["build"], "unexpected argument"},
        {["--fail-on=warning"], "unknown option"},
        {["-i", File.join(root, "missing")], "project directory not found"},
      ]

      cases.each do |args, message|
        status, stdout, stderr = LintCliSpecSupport.run_lint(root, args)
        status.should eq 2
        stdout.should eq ""
        stderr.should contain("mochi lint:")
        stderr.should contain(message)
      end
    end
  end

  it "fails an empty source selection instead of reporting a green run" do
    LintCliSpecSupport.with_project do |root|
      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 2
      stdout.should eq ""
      stderr.should contain("no Ruby source files matched")
    end
  end

  it "reports syntax columns as Unicode characters rather than UTF-8 bytes" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/UnicodeSyntax.rb", <<-RUBY)
        class UnicodeSyntax
          def html
            "é" )
          end
        end
        RUBY

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 1
      stderr.should eq ""
      stdout.should start_with("lib/UnicodeSyntax.rb:3:9: error ruby/syntax:")
    end
  end

  it "reports malformed template source as an analysis limitation" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/MalformedTemplate.rb", <<-RUBY)
        class MalformedTemplate
          @tag_name = "malformed-template"

          def html
            "<p>{@name</p>"
          end
        end
        RUBY

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 1
      stderr.should eq ""
      stdout.should contain("error analysis/limitation:")
      stdout.should contain("unclosed template placeholder")
    end
  end

  it "does not emit diagnostics from excluded support files" do
    LintCliSpecSupport.with_project do |root|
      LintCliSpecSupport.write_source(root, "lib/support.rb", <<-RUBY)
        class SupportWidget
          @tag_name = "support-widget"

          def html
            "<p>{@broken</p>"
          end
        end
        RUBY
      LintCliSpecSupport.write_source(root, "lib/TargetWidget.rb", <<-RUBY)
        require_relative "support"

        class TargetWidget
          @tag_name = "target-widget"

          def html
            %Q{<p>ok</p>}
          end
        end
        RUBY
      File.write(File.join(root, ".mochi-lint.yml"), <<-YAML)
        version: 1
        include: ["lib/TargetWidget.rb"]
        YAML

      status, stdout, stderr = LintCliSpecSupport.run_lint(root)

      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""
    end
  end
end
