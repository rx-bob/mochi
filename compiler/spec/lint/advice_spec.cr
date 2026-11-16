require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/money_advice"
require "../../src/lint/rules/timer_advice"
require "../../src/tooling/lint_runner"

module LintAdviceSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_advice", &)
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
      Lint::Diagnostics.sort(
        Lint::Rules::MoneyAdvice.diagnostics(project_index) +
        Lint::Rules::TimerAdvice.diagnostics(project_index)
      )
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

describe Lint::Rules::MoneyAdvice do
  it "is off by default" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/MoneyLabels.rb", <<-RUBY)
        class MoneyLabels
          def label(value, scale)
            MochiFormat.currency((value * scale).round, "USD")
          end
        end
        RUBY

      LintAdviceSpecSupport.diagnostics(root).should be_empty
      LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::MoneyAdvice::RULE => "off"}).should be_empty
    end
  end

  it "also reports a direct conversion inside a template expression" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/InlineMoney.rb", <<-RUBY)
        class InlineMoney
          @tag_name = "inline-money"

          def html
            %Q{<span>{MochiFormat.currency((@value * 100).round, "USD")}</span>}
          end
        end
        RUBY

      diagnostics = LintAdviceSpecSupport.rule(
        LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::MoneyAdvice::RULE => "warning"}),
        Lint::Rules::MoneyAdvice::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.path.should eq "lib/InlineMoney.rb"
      diagnostics.first.start_line.should eq 5
    end
  end

  it "reports direct scaled rounding at currency display and keeps unrelated shapes safe" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/MoneyLabels.rb", <<-RUBY)
        class MoneyLabels
          def scaled(value, scale)
            MochiFormat.currency((value * scale).round, "USD")
          end

          def grouped(value, scale)
            MochiFormat.currency(
              ((value * scale)).round.to_i,
              "USD",
            )
          end

          def truncated(value, scale)
            MochiFormat.currency((value * scale).to_i, "USD")
          end

          def zero_precision(value, scale)
            MochiFormat.currency((value * scale).round(0), "USD")
          end

          def precision(value, scale)
            MochiFormat.currency((value * scale).round(2), "USD")
          end

          def exact(ledger)
            cents = MochiMoney.round_half_up(ledger)
            MochiFormat.currency(cents, "USD")
          end

          def unrelated(value)
            (value * 100).round
          end

          def dynamic(value)
            MochiFormat.currency(convert(value), "USD")
          end
        end
        RUBY

      diagnostics = LintAdviceSpecSupport.rule(
        LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::MoneyAdvice::RULE => "warning"}),
        Lint::Rules::MoneyAdvice::RULE,
      )
      diagnostics.size.should eq 4
      diagnostics.map(&.start_line).should eq [3, 8, 14, 18]
      diagnostics.each do |diagnostic|
        diagnostic.path.should eq "lib/MoneyLabels.rb"
        diagnostic.severity.should eq Lint::Severity::Warning
        diagnostic.message.should contain "review prompt"
        diagnostic.message.should contain "MochiMoney"
        diagnostic.suggestion.not_nil!.should contain "MochiMoney"
        diagnostic.suggestion.not_nil!.should contain "round_*"
        diagnostic.suggestion.not_nil!.should contain "MochiFormat.currency"
      end
    end
  end
end

describe Lint::Rules::TimerAdvice do
  it "is off by default" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/HiddenScheduler.rb", <<-RUBY)
        class HiddenScheduler
          @tag_name = "hidden-scheduler"
          @ticks = 0
          @phase = false

          def html
            %Q{
              <div class="timer-driver hidden" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end
        RUBY

      LintAdviceSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "reports a hidden animation callback that restarts its driver and repeats local work" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/HiddenScheduler.rb", <<-RUBY)
        class HiddenScheduler
          @tag_name = "hidden-scheduler"
          @ticks = 0
          @phase = false

          def html
            %Q{
              <div class="timer-driver hidden" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end
        RUBY

      diagnostics = LintAdviceSpecSupport.rule(
        LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::TimerAdvice::RULE => "warning"}),
        Lint::Rules::TimerAdvice::RULE,
      )
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.path.should eq "lib/HiddenScheduler.rb"
      diagnostic.start_line.should eq 8
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.message.should contain "review prompt"
      diagnostic.message.should contain "advance"
      diagnostic.message.should contain "Mochi.every"
      diagnostic.suggestion.not_nil!.should contain "Mochi.every"
      diagnostic.suggestion.not_nil!.should contain "Mochi.after"
      diagnostic.suggestion.not_nil!.should contain "mount-owned cancellation"
    end
  end

  it "uses local CSS evidence for a hidden driver" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/CssHiddenScheduler.rb", <<-RUBY)
        class CssHiddenScheduler
          @tag_name = "css-hidden-scheduler"
          @ticks = 0
          @phase = false

          def html
            %Q{
              <div class="timer-driver" data-phase="{@phase}" onanimationiteration="{advance}"></div>
            }
          end

          def css
            %Q{
              .timer-driver {
                visibility: hidden;
                animation: tick 1s linear;
              }
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end
        RUBY

      LintAdviceSpecSupport.rule(
        LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::TimerAdvice::RULE => "warning"}),
        Lint::Rules::TimerAdvice::RULE,
      ).size.should eq 1
    end
  end

  it "leaves visual completion, opaque callbacks, and non-restarting loops unreported" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/TimerSafe.rb", <<-RUBY)
        class VisualSpinner
          @tag_name = "visual-spinner"
          @shown = false
          @message = ""

          def html
            %Q{
              <div class="spinner {@shown}" onanimationend="{finish}"></div>
            }
          end

          def css
            %Q{
              .spinner {
                opacity: 0;
                animation: fade 1s linear;
              }
            }
          end

          def finish
            @shown = true
            @message = "done"
          end
        end

        class UnknownScheduler
          @tag_name = "unknown-scheduler"
          @phase = false

          def html
            %Q{
              <div hidden class="driver" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            perform
          end
        end

        class NoRestartScheduler
          @tag_name = "no-restart-scheduler"
          @ticks = 0
          @phase = false

          def html
            %Q{
              <div hidden class="driver" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end

        class ExistingTimerScheduler
          @tag_name = "existing-timer-scheduler"
          @phase = false
          @ticks = 0

          def html
            %Q{
              <div hidden class="driver" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
            Mochi.every(100, :advance)
          end
        end
        RUBY

      LintAdviceSpecSupport.rule(
        LintAdviceSpecSupport.diagnostics(root, {Lint::Rules::TimerAdvice::RULE => "warning"}),
        Lint::Rules::TimerAdvice::RULE,
      ).should be_empty
    end
  end
end

describe "opt-in advice integration" do
  it "honors named-reason suppressions for both rules" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/SuppressedAdvice.rb", <<-RUBY)
        class SuppressedAdvice
          @tag_name = "suppressed-advice"
          @ticks = 0
          @phase = false

          # mochi-lint: disable-next money/float-to-minor-units -- Display rounding is reviewed separately
          def label(value, scale)
            MochiFormat.currency((value * scale).round, "USD")
          end

          def html
            %Q{
              <!-- mochi-lint: disable-next migration/css-timer -- Existing driver is reviewed separately -->
              <div hidden class="driver" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end
        RUBY

      LintAdviceSpecSupport.config(root, {
        Lint::Rules::MoneyAdvice::RULE => "warning",
        Lint::Rules::TimerAdvice::RULE => "warning",
      })
      status, stdout, stderr = LintAdviceSpecSupport.run_lint(root)
      status.should eq 0
      stdout.should be_empty
      stderr.should be_empty
    end
  end

  it "keeps both rules off by default and fails with exit 1 when enabled" do
    LintAdviceSpecSupport.with_project do |root|
      LintAdviceSpecSupport.write(root, "lib/AdviceCLI.rb", <<-RUBY)
        class AdviceCLI
          @tag_name = "advice-cli"
          @ticks = 0
          @phase = false

          def label(value, scale)
            MochiFormat.currency((value * scale).round, "USD")
          end

          def html
            %Q{
              <div hidden class="driver" data-phase="{@phase}" onanimationend="{advance}"></div>
            }
          end

          def advance
            @phase = !@phase
            @ticks = @ticks + 1
          end
        end
        RUBY

      LintAdviceSpecSupport.config(root)
      status, stdout, _stderr = LintAdviceSpecSupport.run_lint(root)
      status.should eq 0
      stdout.should be_empty

      LintAdviceSpecSupport.config(root, {
        Lint::Rules::MoneyAdvice::RULE => "warning",
        Lint::Rules::TimerAdvice::RULE => "warning",
      })
      status, stdout, stderr = LintAdviceSpecSupport.run_lint(root)
      status.should eq 1
      stderr.should be_empty
      stdout.should contain "money/float-to-minor-units"
      stdout.should contain "migration/css-timer"
    end
  end
end
