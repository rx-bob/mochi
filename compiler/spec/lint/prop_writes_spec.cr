require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/prop_writes"
require "../../src/tooling/lint_runner"

module LintPropWritesSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_prop_writes", &)
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
      Lint::Rules::PropWrites.diagnostics(project_index)
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
end

describe Lint::Rules::PropWrites do
  it "reports direct assignments, indexed writes, multiple assignment, and direct mutation" do
    LintPropWritesSpecSupport.with_project do |root|
      LintPropWritesSpecSupport.write(root, "lib/Counter.rb", <<-RUBY)
        class Counter
          @tag_name = "counter"
          prop :label, String
          prop :rows, Array
          prop :enabled, Boolean

          def initialize
            @label = "local"
            @rows = []
          end

          def update
            @label = "next"
            @label += "!"
            @rows[0] = 1
            @rows[0] += 2
            @rows << 3
            @rows.clear
            @rows.push(4)
            @rows, @enabled = [], true
          end

          def safe
            label = @label
            rows = @rows
            rows << 1
            @other = 1
          end

          def html
            %Q{<span>{@label}</span>}
          end
        end
        RUBY

      found = LintPropWritesSpecSupport.rule(
        LintPropWritesSpecSupport.diagnostics(root),
        "components/prop-write",
      )

      found.size.should eq 11
      found.first.message.should contain("declared prop '@label'")
      found.first.message.should contain("initialize")
      found.first.suggestion.not_nil!.should contain("overwritten")
      found.map(&.start_line).should eq [8, 9, 13, 14, 15, 16, 17, 18, 19, 20, 20]
      found.count { |diagnostic| diagnostic.message.includes?("'@rows'") }.should eq 7
      found.count { |diagnostic| diagnostic.message.includes?("'@enabled'") }.should eq 1
      found.none? { |diagnostic| diagnostic.message.includes?("'@other'") }.should be_true
    end
  end

  it "reports two-way form bindings to declared props but not unrelated ivars" do
    LintPropWritesSpecSupport.with_project do |root|
      LintPropWritesSpecSupport.write(root, "lib/Editor.rb", <<-RUBY)
        class Editor
          @tag_name = "editor"
          prop :title, String
          prop :enabled, Boolean
          @draft

          def html
            %Q{
              <input bind:value="@title">
              <input type="checkbox" bind:checked="@enabled">
              <input bind:value="@draft">
              <input bind:value="{@draft}">
              <input bind:value="@missing">
            }
          end
        end
        RUBY

      found = LintPropWritesSpecSupport.rule(
        LintPropWritesSpecSupport.diagnostics(root),
        "components/prop-write",
      )

      found.size.should eq 2
      found.map(&.message).should eq [
        "two-way binding 'bind:value' writes declared prop '@title'; declared props are read-only input snapshots",
        "two-way binding 'bind:checked' writes declared prop '@enabled'; declared props are read-only input snapshots",
      ]
      found.map(&.start_line).should eq [9, 10]
    end
  end

  it "emits nothing when the rule is off" do
    LintPropWritesSpecSupport.with_project do |root|
      LintPropWritesSpecSupport.write(root, "lib/Counter.rb", <<-RUBY)
        class Counter
          @tag_name = "counter"
          prop :label, String

          def update
            @label = "next"
          end

          def html
            %Q{<span>{@label}</span>}
          end
        end
        RUBY

      found = LintPropWritesSpecSupport.diagnostics(
        root,
        {"components/prop-write" => "off"},
      )
      found.should be_empty
    end
  end

  it "fails the CLI with a warning for a prop write" do
    LintPropWritesSpecSupport.with_project do |root|
      LintPropWritesSpecSupport.write(root, "lib/Counter.rb", <<-RUBY)
        class Counter
          @tag_name = "counter"
          prop :label, String

          def update
            @label = "next"
          end

          def html
            %Q{<span>{@label}</span>}
          end
        end
        RUBY

      status, stdout, stderr = LintPropWritesSpecSupport.run_lint(root)

      status.should eq 1
      stderr.should eq ""
      stdout.should contain("warning components/prop-write:")
      stdout.should contain("declared prop '@label'")
    end
  end
end
