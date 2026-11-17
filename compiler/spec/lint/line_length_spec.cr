require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/suppressions"
require "../../src/lint/rules/line_length"
require "../../src/tooling/lint_runner"

module LintLineLengthSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_line_length", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(File.join(root, "lib"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write(root : String, relative_path : String, source : String) : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def config(root : String, rules : Hash(String, String)? = nil) : Lint::Config
    yaml = String.build do |io|
      io << "version: 1\n"
      io << "include:\n  - \"lib/**/*.rb\"\n"
      if rules
        io << "rules:\n"
        rules.each { |rule, value| io << "  #{rule}: #{value}\n" }
      end
    end
    write(root, ".mochi-lint.yml", yaml)
    Lint::Config.load(root, true, nil, root)
  end

  def diagnostics(root : String, rules : Hash(String, String)? = nil) : Array(Lint::Diagnostic)
    lint_config = config(root, rules)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    index = Lint::ProjectIndex.build(files, lint_config)
    begin
      raw = Lint::Rules::LineLength.diagnostics(index)
      Lint::Suppressions.apply(index, raw)
    ensure
      index.close
    end
  end

  def run_lint(root : String, args = [] of String) : Tuple(Int32, String, String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = LintRunner.new.run(["-i", root] + args, output, error)
    {status, output.to_s, error.to_s}
  end

  def source(line : String, line_ending = "\n") : String
    "class Widget#{line_ending}  def x#{line_ending}#{line}#{line_ending}  end#{line_ending}end#{line_ending}"
  end
end

describe Lint::Rules::LineLength do
  it "is off by default and reports only lines over the configured maximum" do
    LintLineLengthSpecSupport.with_project do |root|
      line = "    " + ("x" * 14)
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", LintLineLengthSpecSupport.source(line))

      LintLineLengthSpecSupport.diagnostics(root).should be_empty

      rules = {"metrics/line-length" => "{severity: warning, max: 18}"}
      LintLineLengthSpecSupport.diagnostics(root, rules).should be_empty

      rules = {"metrics/line-length" => "{severity: warning, max: 17}"}
      diagnostics = LintLineLengthSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.rule.should eq Lint::Rules::LineLength::RULE
      diagnostic.start_line.should eq 3
      diagnostic.start_column.should eq 1
      diagnostic.end_line.should eq 3
      diagnostic.end_column.should eq 19
      diagnostic.message.should eq "line has 18 characters; maximum is 17"
      diagnostic.suggestion.should eq "Wrap this line or move embedded data outside the method."
    end
  end

  it "counts Unicode characters and ignores carriage returns in CRLF sources" do
    LintLineLengthSpecSupport.with_project do |root|
      line = "    \"日本語\""
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", LintLineLengthSpecSupport.source(line))

      rules = {"metrics/line-length" => "{severity: warning, max: 9}"}
      LintLineLengthSpecSupport.diagnostics(root, rules).should be_empty

      rules = {"metrics/line-length" => "{severity: warning, max: 8}"}
      diagnostics = LintLineLengthSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "line has 9 characters; maximum is 8"

      line = "    " + ("x" * 14)
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", LintLineLengthSpecSupport.source(line, "\r\n"))
      rules = {"metrics/line-length" => "{severity: warning, max: 18}"}
      LintLineLengthSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "can be disabled explicitly and suppressed for one method" do
    LintLineLengthSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def long
            xxxxxxxxxxxxxxxxxxxx
          end
        end
        RUBY
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"metrics/line-length" => "off"}
      LintLineLengthSpecSupport.diagnostics(root, rules).should be_empty

      source = <<-RUBY
        class Widget
          # mochi-lint: disable-next metrics/line-length -- generated lookup table
          def long
            xxxxxxxxxxxxxxxxxxxx
          end
        end
        RUBY
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"metrics/line-length" => "{severity: warning, max: 10}"}
      LintLineLengthSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "fails the CLI when enabled and passes when the default is off" do
    LintLineLengthSpecSupport.with_project do |root|
      line = "    " + ("x" * 14)
      LintLineLengthSpecSupport.write(root, "lib/Widget.rb", LintLineLengthSpecSupport.source(line))

      status, output, error = LintLineLengthSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty

      LintLineLengthSpecSupport.config(root, {"metrics/line-length" => "{severity: warning, max: 17}"})
      status, output, error = LintLineLengthSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:3:1: warning metrics/line-length: line has 18 characters; maximum is 17"
      error.should be_empty
    end
  end
end
