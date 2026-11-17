require "spec"
require "file_utils"
require "random"

require "../../src/lint/rules/accessibility"
require "../../src/lint/rules/child_props"
require "../../src/lint/rules/component_methods"
require "../../src/lint/config"
require "../../src/lint/rules/event_payloads"
require "../../src/lint/file_discovery"
require "../../src/lint/rules/handlers"
require "../../src/lint/rules/method_length"
require "../../src/lint/rules/nesting_depth"
require "../../src/lint/project_index"
require "../../src/lint/rules/prop_writes"
require "../../src/lint/rules/row_identity"
require "../../src/lint/suppressions"
require "../../src/tooling/lint_runner"

module LintSuppressionsSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_suppressions", &)
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
        rules.each { |rule, level| io << "  #{rule}: #{level}\n" }
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
      raw =
        project_index.diagnostics +
          Lint::Rules::Handlers.diagnostics(project_index) +
          Lint::Rules::ComponentMethods.diagnostics(project_index) +
          Lint::Rules::MethodLength.diagnostics(project_index) +
          Lint::Rules::NestingDepth.diagnostics(project_index) +
          Lint::Rules::Accessibility.diagnostics(project_index) +
          Lint::Rules::ChildProps.diagnostics(project_index) +
          Lint::Rules::PropWrites.diagnostics(project_index) +
          Lint::Rules::RowIdentity.diagnostics(project_index) +
          Lint::Rules::EventPayloads.diagnostics(project_index)
      Lint::Suppressions.apply(project_index, raw)
    ensure
      project_index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end

  def run_lint(root : String) : Tuple(Int32, String, String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = LintRunner.new.run(["-i", root], stdout, stderr, root)
    {status, stdout.to_s, stderr.to_s}
  end

  def long_method_source(lines : Int32, name = "long") : String
    String.build do |io|
      io << "class Widget\n"
      io << "  def " << name << "\n"
      lines.times { |index| io << "    value_#{index} = #{index}\n" }
      io << "  end\n"
      io << "end\n"
    end
  end

  def component_source(count : Int32) : String
    String.build do |io|
      io << "class LargeWidget\n"
      io << "  @tag_name = \"large-widget\"\n"
      count.times do |index|
        io << "  def method_#{index}; end\n"
      end
      io << "end\n"
    end
  end
end

describe Lint::Suppressions do
  it "suppresses a named Ruby finding only within its method scope" do
    LintSuppressionsSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          # mochi-lint: disable-next metrics/method-length -- Explicit protocol dispatch stays together for review
          def long
        #{("    value = 1 # line\n") * 61}  end

          def sibling
        #{("    value = 1 # line\n") * 61}  end
        end
        RUBY
      LintSuppressionsSpecSupport.write(root, "lib/Widget.rb", source)

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      method_diagnostics = LintSuppressionsSpecSupport.rule(diagnostics, "metrics/method-length")
      method_diagnostics.size.should eq 1
      method_diagnostics.first.message.should contain "method 'sibling'"
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "does not let a directive suppress the same byte range in another file" do
    LintSuppressionsSpecSupport.with_project do |root|
      body = ->(suffix : Char) do
        String.build do |io|
          io << "class Widget" << suffix << "\n"
          0.upto(1) do |method|
            io << "  def method_#{method}\n"
            61.times { |index| io << "    value_#{index} = #{index}\n" }
            io << "  end\n\n"
          end
          io << "end\n"
        end
      end

      directive = "# mochi-lint: disable-next metrics/method-length -- Same layout is reviewed here\n"
      padding = "# " + ("x" * (directive.bytesize - 3)) + "\n"
      padding.bytesize.should eq directive.bytesize

      LintSuppressionsSpecSupport.write(root, "lib/WidgetA.rb", directive + body.call('A'))
      LintSuppressionsSpecSupport.write(root, "lib/WidgetB.rb", padding + body.call('B'))

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      method_diagnostics = LintSuppressionsSpecSupport.rule(diagnostics, "metrics/method-length")
      method_diagnostics.size.should eq 2
      method_diagnostics.each { |diagnostic| diagnostic.path.should eq "lib/WidgetB.rb" }
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "suppresses a component method count at the class declaration" do
    LintSuppressionsSpecSupport.with_project do |root|
      source = "# mochi-lint: disable-next metrics/component-methods -- This screen owns one cohesive workflow\n" +
               LintSuppressionsSpecSupport.component_source(41)
      LintSuppressionsSpecSupport.write(root, "lib/LargeWidget.rb", source)

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      LintSuppressionsSpecSupport.rule(diagnostics, "metrics/component-methods").should be_empty
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "suppresses template controls inside one sibling and not the next" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Buttons.rb", <<-RUBY)
        class Buttons
          @tag_name = "buttons"

          def html
            %Q{
              <!-- mochi-lint: disable-next accessibility/control-name -- The row label names this repeated action -->
              <button></button>
              <button></button>
            }
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      control = LintSuppressionsSpecSupport.rule(diagnostics, "accessibility/control-name")
      control.size.should eq 1
      control.first.start_line.should eq 8
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "suppresses template controls through a structural block and nested row" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/NestedButtons.rb", <<-RUBY)
        class NestedButtons
          @tag_name = "nested-buttons"

          def html
            %Q{
              <!-- mochi-lint: disable-next accessibility/control-name -- The block has one labelled action -->
              {if @show}
                <button></button>
              {end}
              {each @rows as row}
                <!-- mochi-lint: disable-next accessibility/control-name -- The row label names this action -->
                <button></button>
              {end}
            }
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      LintSuppressionsSpecSupport.rule(diagnostics, "accessibility/control-name").should be_empty
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "ignores directive-looking comments inside Mochi.raw placeholder strings" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/RawComment.rb", <<-RUBY)
        class RawComment
          @tag_name = "raw-comment"

          def html
            %Q{
              {Mochi.raw("<!-- mochi-lint: disable-next accessibility/control-name -- Not a directive -->")}
              <button></button>
            }
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      LintSuppressionsSpecSupport.rule(diagnostics, "accessibility/control-name").size.should eq 1
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "ignores directive-looking text inside ordinary Ruby strings" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/StringComment.rb", <<-RUBY)
        class StringComment
          def long
            note = "# mochi-lint: disable-next metrics/method-length -- Not a comment"
        #{("    value = 1\n") * 60}  end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      LintSuppressionsSpecSupport.rule(diagnostics, "metrics/method-length").size.should eq 1
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).should be_empty
    end
  end

  it "reports unused and disabled-rule directives" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Stale.rb", <<-RUBY)
        class Stale
          # mochi-lint: disable-next metrics/method-length -- No longer needed
          def short
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
      suppression.size.should eq 1
      suppression.first.message.should contain "does not suppress an enabled diagnostic"

      LintSuppressionsSpecSupport.write(root, "lib/Stale.rb", <<-RUBY)
        class Stale
          # mochi-lint: disable-next metrics/method-length -- Kept for review
          def long
        #{("    value = 1\n") * 61}  end
        end
        RUBY

      rules = {"metrics/method-length" => "off"}
      diagnostics = LintSuppressionsSpecSupport.diagnostics(root, rules)
      suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
      suppression.size.should eq 1
      suppression.first.message.should contain "unused because the rule is off"
    end
  end

  it "rejects malformed, wildcard, unknown, and unsuppressible directives" do
    LintSuppressionsSpecSupport.with_project do |root|
      cases = {
        "# mochi-lint: disable-next metrics/method-length\n"          => "nonempty reason",
        "# mochi-lint: disable-next * -- Broad exception\n"           => "wildcard",
        "# mochi-lint: disable-next unknown/rule -- Reason\n"         => "unknown lint rule",
        "# mochi-lint: disable metrics/method-length -- File-wide\n"  => "file-wide",
        "# mochi-lint: disable-next ruby/syntax -- Parser recovery\n" => "cannot be suppressed",
      }

      cases.each do |directive, expected|
        LintSuppressionsSpecSupport.write(root, "lib/Invalid.rb", <<-RUBY)
          #{directive}class Invalid
            def short
            end
          end
          RUBY
        diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
        suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
        suppression.size.should eq 1
        suppression.first.message.should contain expected
      end
    end
  end

  it "reports duplicate and overlapping directives for one rule" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Duplicate.rb", <<-RUBY)
        class Duplicate
          # mochi-lint: disable-next metrics/nesting-depth -- Keep nested states together
          # mochi-lint: disable-next metrics/nesting-depth -- Keep nested states together
          def nested
            if one
              if two
              end
            end
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root, {"metrics/nesting-depth" => "{severity: warning, max: 1}"})
      suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
      suppression.size.should eq 2
      suppression.all? { |diagnostic| diagnostic.message.includes?("duplicate suppression") }.should be_true

      LintSuppressionsSpecSupport.write(root, "lib/Duplicate.rb", <<-RUBY)
        class Overlap
          # mochi-lint: disable-next metrics/nesting-depth -- Method-wide exception
          def nested
            # mochi-lint: disable-next metrics/nesting-depth -- Inner exception
            if one
              if two
              end
            end
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root, {"metrics/nesting-depth" => "{severity: warning, max: 1}"})
      suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
      suppression.size.should eq 2
      suppression.all? { |diagnostic| diagnostic.message.includes?("overlapping suppression") }.should be_true
    end
  end

  it "reports orphan directives at the end of a Ruby or template scope" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Orphan.rb", <<-RUBY)
        class Orphan
          @tag_name = "orphan"

          def short
            # mochi-lint: disable-next metrics/method-length -- End of method
          end

          def html
            %Q{
              <div>
                <!-- mochi-lint: disable-next accessibility/control-name -- End of element -->
              </div>
              <button></button>
            }
          end
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      suppression = LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE)
      suppression.size.should eq 2
      suppression.map(&.message).any?(&.includes?("no following Ruby construct")).should be_true
      suppression.map(&.message).any?(&.includes?("no following template element or block")).should be_true
      LintSuppressionsSpecSupport.rule(diagnostics, "accessibility/control-name").size.should eq 1
    end
  end

  it "does not hide syntax diagnostics" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Broken.rb", <<-RUBY)
        # mochi-lint: disable-next ruby/syntax -- Try to hide parser recovery
        class Broken
          def bad(
        end
        RUBY

      diagnostics = LintSuppressionsSpecSupport.diagnostics(root)
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SYNTAX_RULE).size.should eq 1
      LintSuppressionsSpecSupport.rule(diagnostics, Lint::SUPPRESSION_RULE).size.should eq 1
    end
  end
end

describe LintRunner do
  it "passes with a valid suppression and fails on stale or malformed directives" do
    LintSuppressionsSpecSupport.with_project do |root|
      LintSuppressionsSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          # mochi-lint: disable-next metrics/method-length -- Explicit protocol dispatch stays together for review
          def long
        #{("    value = 1\n") * 61}  end
        end
        RUBY

      status, output, error = LintSuppressionsSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty

      LintSuppressionsSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          # mochi-lint: disable-next metrics/method-length -- Stale exception
          def short
          end
        end
        RUBY

      status, output, error = LintSuppressionsSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lint/suppression"
      output.should contain "does not suppress an enabled diagnostic"
      error.should be_empty

      LintSuppressionsSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          # mochi-lint: disable-next metrics/method-length
          def short
          end
        end
        RUBY

      status, output, error = LintSuppressionsSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "nonempty reason"
      error.should be_empty
    end
  end
end
