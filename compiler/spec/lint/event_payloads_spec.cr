require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/event_payloads"
require "../../src/tooling/lint_runner"

module LintEventPayloadsSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_event_payloads", &)
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
      Lint::Rules::EventPayloads.diagnostics(project_index)
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

describe Lint::Rules::EventPayloads do
  it "normalizes String and Symbol keys and reports type and extra-field mismatches" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer, label: String

          def choose
            self.emit :select, {"id" => "bad", :label => "ok", "extra" => 1}
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.rule(
        LintEventPayloadsSpecSupport.diagnostics(root),
        "correctness/event-payload",
      )

      found.size.should eq 2
      found.first.message.should contain("payload field 'id' expects Integer")
      found.first.message.should contain("got String literal")
      found.first.message.should contain("lib/EventRow.rb:3")
      found.last.message.should contain("payload field 'extra' is not declared")
      found.map(&.start_line).should eq [6, 6]
    end
  end

  it "reports missing fields and extra keys for a literal payload" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer, label: String

          def choose
            emit :select, extra: 1
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.rule(
        LintEventPayloadsSpecSupport.diagnostics(root),
        "correctness/event-payload",
      )

      found.size.should eq 3
      messages = found.map(&.message).join("\n")
      messages.should contain("payload is missing field 'id'")
      messages.should contain("payload is missing field 'label'")
      messages.should contain("payload field 'extra' is not declared")
    end
  end

  it "accepts every literal field type, Integer values for Float fields, and dynamic payloads" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :all, text: String, count: Integer, ratio: Float, active: Boolean, rows: Array, meta: Hash

          def choose
            emit :all, text: "x", count: +1, ratio: -1.5, active: false, rows: [], meta: {}
            emit :all, text: "x\#{@suffix}", count: value, ratio: compute, active: flag, rows: items, meta: data
            emit :all, **payload
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.diagnostics(root)
      found.should be_empty
    end
  end

  it "reports unknown literal event names but leaves dynamic event names and multiple events alone" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer
          event :opened

          def choose
            emit :select, id: 1
            emit :opened
            emit :other
            name = :select
            emit name, id: bad
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.rule(
        LintEventPayloadsSpecSupport.diagnostics(root),
        "correctness/event-payload",
      )

      found.size.should eq 1
      found.first.message.should contain("event 'other' is not declared by 'EventRow'")
      found.first.message.should contain("declared events: select, opened")
      found.first.start_line.should eq 9
    end
  end

  it "rejects literal Integers outside the signed 64-bit range" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer

          def choose
            emit :select, id: 9223372036854775808
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.diagnostics(root)

      found.size.should eq 1
      found.first.message.should contain("outside the signed 64-bit range")
      found.first.message.should contain("lib/EventRow.rb:3")
    end
  end

  it "validates on: subscriptions against known child event declarations" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/ChildRow.rb", <<-RUBY)
        class ChildRow
          @tag_name = "child-row"
          event :select, id: Integer
          event :opened

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY
      LintEventPayloadsSpecSupport.write(root, "lib/ParentList.rb", <<-RUBY)
        class ParentList
          @tag_name = "parent-list"

          def html
            %Q{
              <child-row on:select="{row_selected($event)}" on:missing="{row_selected($event)}"></child-row>
              <unknown-child on:other="{handle}"></unknown-child>
            }
          end

          def row_selected(event)
          end

          def handle
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.rule(
        LintEventPayloadsSpecSupport.diagnostics(root),
        "correctness/event-payload",
      )

      found.size.should eq 1
      found.first.message.should contain("child event 'missing' is not declared on <child-row>")
      found.first.message.should contain("declared events: select, opened")
      found.first.message.should contain("lib/ChildRow.rb")
      found.first.start_line.should eq 6
    end
  end

  it "emits nothing when the rule is off" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer

          def choose
            emit :select, id: "bad"
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      found = LintEventPayloadsSpecSupport.diagnostics(
        root,
        {"correctness/event-payload" => "off"},
      )
      found.should be_empty
    end
  end

  it "fails the CLI with an error for an invalid literal payload" do
    LintEventPayloadsSpecSupport.with_project do |root|
      LintEventPayloadsSpecSupport.write(root, "lib/EventRow.rb", <<-RUBY)
        class EventRow
          @tag_name = "event-row"
          event :select, id: Integer

          def choose
            emit :select, id: "bad"
          end

          def html
            %Q{<button>Choose</button>}
          end
        end
        RUBY

      status, stdout, stderr = LintEventPayloadsSpecSupport.run_lint(root)

      status.should eq 1
      stderr.should eq ""
      stdout.should contain("error correctness/event-payload:")
      stdout.should contain("payload field 'id' expects Integer")
    end
  end
end
