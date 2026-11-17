require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/suppressions"
require "../../src/lint/rules/html_method_length"
require "../../src/tooling/lint_runner"

module LintHtmlMethodLengthSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_html_method_length", &)
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
      raw = Lint::Rules::HtmlMethodLength.diagnostics(index)
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

  def component_source(
    method_lines : Int32,
    tag : String? = "widget-card",
    singleton = false,
    class_name = "Widget",
  ) : String
    body_lines = method_lines - 4
    raise ArgumentError.new("component source needs at least 4 method lines") if body_lines < 0

    String.build do |io|
      io << "class " << class_name << "\n"
      io << "  @tag_name = \"#{tag}\"\n" if tag
      io << "  def " << (singleton ? "self.html" : "html") << "\n"
      io << "    %Q{\n"
      body_lines.times { |index| io << "      <p>row #{index}</p>\n" }
      io << "    }\n"
      io << "  end\n"
      io << "end\n"
    end
  end
end

describe Lint::Rules::HtmlMethodLength do
  it "passes exactly 50 method lines and reports 51" do
    LintHtmlMethodLengthSpecSupport.with_project do |root|
      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", LintHtmlMethodLengthSpecSupport.component_source(50))
      LintHtmlMethodLengthSpecSupport.diagnostics(root).should be_empty

      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", LintHtmlMethodLengthSpecSupport.component_source(51))
      diagnostics = LintHtmlMethodLengthSpecSupport.diagnostics(root)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.rule.should eq Lint::Rules::HtmlMethodLength::RULE
      diagnostic.start_line.should eq 3
      diagnostic.message.should eq "component 'widget-card' html method has 51 lines; maximum is 50"
      diagnostic.suggestion.should eq "Split the markup into typed child components or Ruby helpers."
    end
  end

  it "uses the configured maximum" do
    LintHtmlMethodLengthSpecSupport.with_project do |root|
      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", LintHtmlMethodLengthSpecSupport.component_source(5))

      rules = {"metrics/html-method-length" => "{severity: warning, max: 5}"}
      LintHtmlMethodLengthSpecSupport.diagnostics(root, rules).should be_empty

      rules = {"metrics/html-method-length" => "{severity: warning, max: 4}"}
      diagnostics = LintHtmlMethodLengthSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "component 'widget-card' html method has 5 lines; maximum is 4"
    end
  end

  it "checks only component instance html methods" do
    LintHtmlMethodLengthSpecSupport.with_project do |root|
      LintHtmlMethodLengthSpecSupport.write(
        root,
        "lib/Plain.rb",
        LintHtmlMethodLengthSpecSupport.component_source(60, tag: nil, class_name: "PlainWidget"),
      )
      LintHtmlMethodLengthSpecSupport.diagnostics(root).should be_empty

      LintHtmlMethodLengthSpecSupport.write(
        root,
        "lib/Widget.rb",
        LintHtmlMethodLengthSpecSupport.component_source(60, singleton: true),
      )
      LintHtmlMethodLengthSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "can be disabled and suppressed for one method" do
    LintHtmlMethodLengthSpecSupport.with_project do |root|
      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", LintHtmlMethodLengthSpecSupport.component_source(51))

      rules = {"metrics/html-method-length" => "off"}
      LintHtmlMethodLengthSpecSupport.diagnostics(root, rules).should be_empty

      source = LintHtmlMethodLengthSpecSupport.component_source(51)
        .sub("  def html\n", "  # mochi-lint: disable-next metrics/html-method-length -- generated markup table\n  def html\n")
      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", source)
      LintHtmlMethodLengthSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "fails the CLI by default and passes when disabled" do
    LintHtmlMethodLengthSpecSupport.with_project do |root|
      LintHtmlMethodLengthSpecSupport.write(root, "lib/Widget.rb", LintHtmlMethodLengthSpecSupport.component_source(51))

      status, output, error = LintHtmlMethodLengthSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:3:3: warning metrics/html-method-length: component 'widget-card' html method has 51 lines; maximum is 50"
      error.should be_empty

      LintHtmlMethodLengthSpecSupport.config(root, {"metrics/html-method-length" => "off"})
      status, output, error = LintHtmlMethodLengthSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
