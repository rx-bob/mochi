require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/handlers"
require "../../src/tooling/lint_runner"

module LintHandlersSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_handlers", &)
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

  def diagnostics(root : String, rules : Hash(String, String)? = nil) : Array(Lint::Diagnostic)
    lint_config = config(root, rules)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    index = Lint::ProjectIndex.build(files, lint_config)
    begin
      Lint::Rules::Handlers.diagnostics(index)
    ensure
      index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end
end

describe Lint::Rules::Handlers do
  it "reports a misspelled direct template handler at its authored call site" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          @tag_name = "widget"

          def save
          end

          def html
            %Q{
              <button onclick="{save}">Save</button>
              <button onclick="{missing($event)}">Missing</button>
            }
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      unknown = LintHandlersSpecSupport.rule(diagnostics, "correctness/unknown-handler")

      unknown.size.should eq 1
      unknown.first.message.should contain("'missing'")
      unknown.first.message.should contain("'Widget'")
      unknown.first.suggestion.not_nil!.should contain("missing")
      unknown.first.start_line.should eq 10
    end
  end

  it "checks child events, modifiers, and local inheritance without false positives" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/base.rb", <<-RUBY)
        module SharedHandlers
          def shared
          end
        end

        class BaseWidget
          def base
          end
        end
        RUBY
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        require_relative "base"

        class Widget < BaseWidget
          include SharedHandlers
          @tag_name = "widget"
          prop :label, String, default: ""

          def save
          end

          def select_row(event)
          end

          def choose(id, index)
          end

          def html
            %Q{
              <event-row on:select="{select_row($event)}"></event-row>
              <button onclick.prevent.stop.self="{save}">Save</button>
              <button onclick="{self.save}">Self</button>
              <button onclick="{base}">Base</button>
              <button onclick="{shared}">Shared</button>
              <span onclick="{label}">Label</span>
              {each @rows as row, index}
                <button onclick="{choose(row["id"], index)}">Choose</button>
                <button onclick="{missing_nested}">Missing</button>
              {end}
            }
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      unknown = LintHandlersSpecSupport.rule(diagnostics, "correctness/unknown-handler")

      unknown.size.should eq 1
      unknown.first.message.should contain("missing_nested")
    end
  end

  it "does not report missing handlers on an unresolved external base" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget < ExternalBase
          @tag_name = "widget"

          def html
            %Q{<button onclick="{external_action}">External</button>}
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      LintHandlersSpecSupport.rule(diagnostics, "correctness/unknown-handler").should be_empty
    end
  end

  it "does not check nested row locals, dynamic receivers, or built-in event arguments" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          @tag_name = "widget"

          def html
            %Q{
              {each @rows as row}
                <button onclick="{row.save}">Row method</button>
                <button onclick="{@handler}">Ivar</button>
                <button onclick="{Mochi.focus(:first)}">Focus</button>
                <button onclick="{event}">Event</button>
              {end}
            }
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      LintHandlersSpecSupport.rule(diagnostics, "correctness/unknown-handler").should be_empty
    end
  end

  it "honors the configured off level" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          @tag_name = "widget"

          def html
            %Q{<button onclick="{missing}">Missing</button>}
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(
        root,
        {"correctness/unknown-handler" => "off"},
      )
      LintHandlersSpecSupport.rule(diagnostics, "correctness/unknown-handler").should be_empty
    end
  end

  it "reports missing callbacks, required arguments, and conclusive literal delays" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/TimerWidget.rb", <<-RUBY)
        class TimerWidget
          @tag_name = "timer-widget"

          def initialize
            @once = Mochi.after(0, :tick)
            @poll = Mochi.every(10, "poll")
            @bad_delay = Mochi.after(-1, :tick)
            @bad_type = Mochi.every(1.5, :tick)
            @too_large = Mochi.after(2_147_483_648, :tick)
            @bad_callback = Mochi.after(0, :missing_tick)
            @bad_literal = Mochi.after(0, 7)
            @empty_callback = Mochi.after(0, "")
            @bad_arity = Mochi.after(0, :refresh)
            @dynamic = Mochi.after(0, callback)
          end

          def tick
          end

          def poll
          end

          def refresh(value)
          end

          def html
            %Q{<p>timers</p>}
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      timer = LintHandlersSpecSupport.rule(diagnostics, "correctness/timer-callback")

      timer.size.should eq 7
      timer.map(&.message).any?(&.includes?("missing_tick")).should be_true
      timer.map(&.message).any?(&.includes?("requires 1 required argument")).should be_true
      timer.map(&.message).any?(&.includes?("-1")).should be_true
      timer.map(&.message).any?(&.includes?("1.5")).should be_true
      timer.map(&.message).any?(&.includes?("2_147_483_648")).should be_true
      timer.map(&.message).any?(&.includes?("7")).should be_true
      timer.map(&.message).any?(&.includes?("must name a component method")).should be_true
    end
  end

  it "accepts zero-argument callbacks, optional parameters, and delay boundaries" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/TimerWidget.rb", <<-RUBY)
        class TimerWidget
          @tag_name = "timer-widget"

          def initialize
            @zero = Mochi.after(0, :zero)
            @maximum = Mochi.every(2_147_483_647, "maximum")
            @optional = Mochi.after(1, :optional)
            @splat = Mochi.after(1, :splat)
            @keyword = Mochi.after(1, :keyword)
            @dynamic = Mochi.after(1, callback_name)
          end

          def zero
          end

          def maximum
          end

          def optional(value = 1)
          end

          def splat(*values)
          end

          def keyword(name:)
          end

          def html
            %Q{<p>timers</p>}
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      LintHandlersSpecSupport.rule(diagnostics, "correctness/timer-callback").should be_empty
    end
  end

  it "does not emit timer diagnostics from excluded support source" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "support/Support.rb", <<-RUBY)
        class SupportTimer
          def start
            Mochi.after(0, :missing_tick)
          end
        end
        RUBY
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        require_relative "../support/Support"

        class Widget
          @tag_name = "widget"

          def html
            %Q{<p>ok</p>}
          end
        end
        RUBY

      diagnostics = LintHandlersSpecSupport.diagnostics(root)
      LintHandlersSpecSupport.rule(diagnostics, "correctness/timer-callback").should be_empty
    end
  end

  it "reports handler diagnostics through the lint command" do
    LintHandlersSpecSupport.with_project do |root|
      LintHandlersSpecSupport.write(root, "lib/Widget.rb", <<-RUBY)
        class Widget
          @tag_name = "widget"

          def html
            %Q{<button onclick="{missing}">Missing</button>}
          end
        end
        RUBY

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = LintRunner.new.run([] of String, stdout, stderr, root)

      status.should eq 1
      stderr.to_s.should eq ""
      stdout.to_s.should contain("error correctness/unknown-handler:")
    end
  end
end
