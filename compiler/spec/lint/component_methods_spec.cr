require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/component_methods"
require "../../src/tooling/lint_runner"

module LintComponentMethodsSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_component_methods", &)
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

  def index(root : String, rules : Hash(String, String)? = nil) : Lint::ProjectIndex
    lint_config = config(root, rules)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    Lint::ProjectIndex.build(files, lint_config)
  end

  def diagnostics(root : String, rules : Hash(String, String)? = nil) : Array(Lint::Diagnostic)
    project_index = index(root, rules)
    begin
      Lint::Rules::ComponentMethods.diagnostics(project_index)
    ensure
      project_index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end

  def run_lint(root : String, args = [] of String) : Tuple(Int32, String, String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = LintRunner.new.run(["-i", root] + args, stdout, stderr, root)
    {status, stdout.to_s, stderr.to_s}
  end

  def component_source(count : Int32, tag = "sample-widget", line_ending = "\n") : String
    String.build do |io|
      io << "class SampleWidget" << line_ending
      io << "  @tag_name = \"" << tag << "\"" << line_ending
      count.times do |index|
        io << "  def method_#{index}" << line_ending
        io << "  end" << line_ending
      end
      io << "end" << line_ending
    end
  end

  def plain_class_source(count : Int32) : String
    String.build do |io|
      io << "class PlainHelper\n"
      count.times { |index| io << "  def method_#{index}; end\n" }
      io << "end\n"
    end
  end
end

describe Lint::Rules::ComponentMethods do
  it "passes at 40 methods and reports 41 with the default maximum" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(40))
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty

      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(41))
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.path.should eq "lib/SampleWidget.rb"
      diagnostic.start_line.should eq 1
      diagnostic.start_column.should eq 1
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.message.should eq "component 'sample-widget' has 41 instance methods; maximum is 40"
      diagnostic.suggestion.should eq "Separate responsibilities into typed children or Ruby helpers."
    end
  end

  it "does not count helper classes that have no component tag" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/PlainHelper.rb", LintComponentMethodsSpecSupport.plain_class_source(41))

      LintComponentMethodsSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "counts distinct names across reopenings and reports the component once" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/AlphaWidget.rb", <<-RUBY)
        class AlphaWidget
          @tag_name = "alpha-widget"

          def initialize
          end

          def shared
          end
        end
        RUBY
      LintComponentMethodsSpecSupport.write(root, "lib/BetaWidget.rb", <<-RUBY)
        class AlphaWidget
          def shared
          end

          def extra
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 2}"}
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.path.should eq "lib/AlphaWidget.rb"
      diagnostics.first.start_line.should eq 1
      diagnostics.first.message.should eq "component 'alpha-widget' has 3 instance methods; maximum is 2"

      rules = {"metrics/component-methods" => "{severity: warning, max: 3}"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty
    end
  end

  it "reports at the target declaration that declares the component tag" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/FirstPart.rb", <<-RUBY)
        class SplitWidget
          def one
          end
        end
        RUBY
      LintComponentMethodsSpecSupport.write(root, "lib/SecondPart.rb", <<-RUBY)
        class SplitWidget
          @tag_name = "split-widget"

          def two
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 1}"}
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.path.should eq "lib/SecondPart.rb"
      diagnostics.first.start_line.should eq 1
      diagnostics.first.message.should eq "component 'split-widget' has 2 instance methods; maximum is 1"
    end
  end

  it "counts overridden method names once" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/Overridden.rb", <<-RUBY)
        class Overridden
          @tag_name = "overridden"

          def draw
          end

          def draw
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 1}"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty
    end
  end

  it "excludes nested, inherited, singleton, reader, prop, and event methods" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/DecoratedWidget.rb", <<-RUBY)
        class BaseWidget
          def inherited_one; end
          def inherited_two; end
        end

        class DecoratedWidget < BaseWidget
          @tag_name = "decorated-widget"
          prop :label, String
          event :selected, id: Integer
          attr_reader :name
          attr_accessor :count

          def self.helper_one; end
          def self.helper_two; end

          def initialize
          end

          def html
            %Q{<div></div>}
          end

          def css
            %Q{:host { display: block; }}
          end

          def mounted
          end

          class NestedHelper
            def alpha; end
            def beta; end
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 4}"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty

      rules = {"metrics/component-methods" => "{severity: warning, max: 3}"}
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "component 'decorated-widget' has 4 instance methods; maximum is 3"
    end
  end

  it "reports each component in a namespace and file independently" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/Cards.rb", <<-RUBY)
        module App
          class FirstCard
            @tag_name = "first-card"

            def one; end
            def two; end
          end

          class SecondCard
            @tag_name = "second-card"

            def one; end
            def two; end
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 1}"}
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 2
      diagnostics[0].message.should eq "component 'first-card' has 2 instance methods; maximum is 1"
      diagnostics[0].start_line.should eq 2
      diagnostics[1].message.should eq "component 'second-card' has 2 instance methods; maximum is 1"
      diagnostics[1].start_line.should eq 9
    end
  end

  it "does not penalize large static template or style literals" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/LiteralOnly.rb", <<-RUBY)
        class TemplateOnly
          @tag_name = "template-only"

          def html
            %Q{
              <section>
                <p>row one</p>
                <p>row two</p>
                <p>row three</p>
                <p>row four</p>
              </section>
            }
          end
        end

        class StyleOnly
          @tag_name = "style-only"

          def css
            %Q{
              :host { display: block; }
              .row-one { color: red; }
              .row-two { color: green; }
              .row-three { color: blue; }
              .row-four { color: black; }
            }
          end
        end
        RUBY

      rules = {"metrics/component-methods" => "{severity: warning, max: 1}"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty
    end
  end

  it "uses a configured max and can be turned off" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(3))

      rules = {"metrics/component-methods" => "{severity: warning, max: 2}"}
      diagnostics = LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "component 'sample-widget' has 3 instance methods; maximum is 2"

      rules = {"metrics/component-methods" => "{severity: warning, max: 5}"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty

      rules = {"metrics/component-methods" => "off"}
      LintComponentMethodsSpecSupport.rule(
        LintComponentMethodsSpecSupport.diagnostics(root, rules),
        Lint::Rules::ComponentMethods::RULE,
      ).should be_empty
    end
  end
end

describe LintRunner do
  it "fails the command for a component method warning and passes within the limit" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(41))

      status, output, error = LintComponentMethodsSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "metrics/component-methods: component 'sample-widget' has 41 instance methods; maximum is 40"
      error.should be_empty

      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(40))
      status, output, error = LintComponentMethodsSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end

  it "honors a configured maximum through the command" do
    LintComponentMethodsSpecSupport.with_project do |root|
      LintComponentMethodsSpecSupport.write(root, "lib/SampleWidget.rb", LintComponentMethodsSpecSupport.component_source(3))
      LintComponentMethodsSpecSupport.config(root, {"metrics/component-methods" => "{severity: warning, max: 2}"})

      status, output, error = LintComponentMethodsSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "metrics/component-methods: component 'sample-widget' has 3 instance methods; maximum is 2"
      error.should be_empty
    end
  end
end
