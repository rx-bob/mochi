require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/suppressions"
require "../../src/lint/rules/class_variables"
require "../../src/tooling/lint_runner"

module LintClassVariablesSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_class_variables", &)
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
      raw = Lint::Rules::ClassVariables.diagnostics(index)
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
    class_variables : Int32,
    tag : String? = "widget-card",
    class_name = "Widget",
    method_variables = 0,
    nested_variables = 0,
  ) : String
    String.build do |io|
      io << "class " << class_name << "\n"
      io << "  @tag_name = \"#{tag}\"\n" if tag
      class_variables.times { |index| io << "  @state_#{index} = nil\n" }
      if nested_variables > 0
        io << "  class Helper\n"
        nested_variables.times { |index| io << "    @nested_#{index} = nil\n" }
        io << "  end\n"
      end
      io << "  def html\n"
      io << "    %Q{<p>ok</p>}\n"
      io << "  end\n"
      method_variables.times do |index|
        io << "  def touch_#{index}\n"
        io << "    @temporary_#{index} = nil\n"
        io << "  end\n"
      end
      io << "end\n"
    end
  end
end

describe Lint::Rules::ClassVariables do
  it "passes exactly 10 authored variables and reports 11" do
    LintClassVariablesSpecSupport.with_project do |root|
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", LintClassVariablesSpecSupport.component_source(10))
      LintClassVariablesSpecSupport.diagnostics(root).should be_empty

      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", LintClassVariablesSpecSupport.component_source(11))
      diagnostics = LintClassVariablesSpecSupport.diagnostics(root)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.rule.should eq Lint::Rules::ClassVariables::RULE
      diagnostic.start_line.should eq 1
      diagnostic.message.should eq "component 'widget-card' declares 11 class variables; maximum is 10"
      diagnostic.suggestion.should eq "Group related state into a plain Ruby object or typed child components."
    end
  end

  it "counts distinct names and ignores tag metadata, methods, and nested classes" do
    LintClassVariablesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget-card"
          @a = nil
          @a = 1
          9.times { @a = 2 }
          #{"@b = nil\n" * 9}
          def html
            @method_only = nil
            %Q{<p>ok</p>}
          end

          class Helper
            @nested = nil
          end
        end
        RUBY
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", source)
      LintClassVariablesSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "counts variables from reopened declarations once" do
    LintClassVariablesSpecSupport.with_project do |root|
      source = String.build do |io|
        io << "class Widget\n"
        io << "  @tag_name = \"widget-card\"\n"
        10.times { |index| io << "  @state_#{index} = nil\n" }
        io << "end\n\n"
        io << "class Widget\n"
        io << "  @state_10 = nil\n"
        io << "end\n"
      end
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", source)
      diagnostics = LintClassVariablesSpecSupport.diagnostics(root)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "component 'widget-card' declares 11 class variables; maximum is 10"
    end
  end

  it "uses the configured maximum, can be disabled, and can be suppressed" do
    LintClassVariablesSpecSupport.with_project do |root|
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", LintClassVariablesSpecSupport.component_source(11))

      rules = {"metrics/class-variables" => "{severity: warning, max: 11}"}
      LintClassVariablesSpecSupport.diagnostics(root, rules).should be_empty

      rules = {"metrics/class-variables" => "off"}
      LintClassVariablesSpecSupport.diagnostics(root, rules).should be_empty

      source = "# mochi-lint: disable-next metrics/class-variables -- generated state table\n" +
               LintClassVariablesSpecSupport.component_source(11)
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", source)
      LintClassVariablesSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "fails the CLI by default and passes when disabled" do
    LintClassVariablesSpecSupport.with_project do |root|
      LintClassVariablesSpecSupport.write(root, "lib/Widget.rb", LintClassVariablesSpecSupport.component_source(11))

      status, output, error = LintClassVariablesSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:1:1: warning metrics/class-variables: component 'widget-card' declares 11 class variables; maximum is 10"
      error.should be_empty

      LintClassVariablesSpecSupport.config(root, {"metrics/class-variables" => "off"})
      status, output, error = LintClassVariablesSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
