require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/suppressions"
require "../../src/lint/rules/method_missing"
require "../../src/tooling/lint_runner"

module LintMethodMissingSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_method_missing", &)
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
      raw = Lint::Rules::MethodMissing.diagnostics(index)
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
    tag : String? = "widget-card",
    hooks = ["method_missing", "respond_to_missing?"],
    class_name = "Widget",
  ) : String
    String.build do |io|
      io << "class " << class_name << "\n"
      io << "  @tag_name = \"#{tag}\"\n" if tag
      io << "  def html\n"
      io << "    %Q{<p>ok</p>}\n"
      io << "  end\n"
      hooks.each do |hook|
        io << "  def " << hook << "(name, *args)\n"
        io << "    name\n"
        io << "  end\n"
      end
      io << "end\n"
    end
  end
end

describe Lint::Rules::MethodMissing do
  it "reports direct method_missing and respond_to_missing? definitions" do
    LintMethodMissingSpecSupport.with_project do |root|
      LintMethodMissingSpecSupport.write(root, "lib/Widget.rb", LintMethodMissingSpecSupport.component_source)
      diagnostics = LintMethodMissingSpecSupport.diagnostics(root)
      diagnostics.size.should eq 2
      diagnostics.map(&.start_line).should eq [6, 9]
      diagnostics.each do |diagnostic|
        diagnostic.severity.should eq Lint::Severity::Error
        diagnostic.rule.should eq Lint::Rules::MethodMissing::RULE
        diagnostic.suggestion.should eq "Define each delegated method explicitly or call a named Ruby helper."
      end
      diagnostics.map(&.message).should eq [
        "component 'widget-card' defines 'method_missing', which can bypass template method checks",
        "component 'widget-card' defines 'respond_to_missing?', which can bypass template method checks",
      ]
    end
  end

  it "ignores non-component classes and singleton hooks" do
    LintMethodMissingSpecSupport.with_project do |root|
      LintMethodMissingSpecSupport.write(root, "lib/Plain.rb", LintMethodMissingSpecSupport.component_source(tag: nil, class_name: "PlainWidget"))
      LintMethodMissingSpecSupport.diagnostics(root).should be_empty

      source = <<-RUBY
        class Widget
          @tag_name = "widget-card"
          def self.method_missing(name, *args)
            name
          end

          def html
            %Q{<p>ok</p>}
          end
        end
        RUBY
      LintMethodMissingSpecSupport.write(root, "lib/Widget.rb", source)
      LintMethodMissingSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "can be disabled and suppressed for one definition" do
    LintMethodMissingSpecSupport.with_project do |root|
      LintMethodMissingSpecSupport.write(root, "lib/Widget.rb", LintMethodMissingSpecSupport.component_source)

      rules = {"correctness/method-missing" => "off"}
      LintMethodMissingSpecSupport.diagnostics(root, rules).should be_empty

      source = LintMethodMissingSpecSupport.component_source(hooks: ["method_missing"])
        .sub("  def method_missing(name, *args)\n", "  # mochi-lint: disable-next correctness/method-missing -- delegation is confined to a named helper\n  def method_missing(name, *args)\n")
      LintMethodMissingSpecSupport.write(root, "lib/Widget.rb", source)
      LintMethodMissingSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "fails the CLI by default and passes when disabled" do
    LintMethodMissingSpecSupport.with_project do |root|
      LintMethodMissingSpecSupport.write(root, "lib/Widget.rb", LintMethodMissingSpecSupport.component_source)

      status, output, error = LintMethodMissingSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:6:3: error correctness/method-missing: component 'widget-card' defines 'method_missing', which can bypass template method checks"
      output.should contain "lib/Widget.rb:9:3: error correctness/method-missing: component 'widget-card' defines 'respond_to_missing?', which can bypass template method checks"
      error.should be_empty

      LintMethodMissingSpecSupport.config(root, {"correctness/method-missing" => "off"})
      status, output, error = LintMethodMissingSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
