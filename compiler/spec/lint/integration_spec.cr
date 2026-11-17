require "spec"
require "file_utils"
require "json"
require "random"

require "../../src/lint/config"
require "../../src/lint/rule_registry"
require "../../src/tooling/lint_runner"

module LintIntegrationSpecSupport
  extend self

  CONTRACT_PATH = File.expand_path("../../../references/LINT_CONTRACT.md", __DIR__)

  def with_project(prefix = "mochi_lint_integration", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(File.join(root, "lib"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write_source(root : String, relative_path : String, source : String) : Nil
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def run_lint(root : String, args : Array(String) = [] of String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = LintRunner.new.run(args, stdout, stderr, root)
    {status, stdout.to_s, stderr.to_s}
  end

  def write_contract_project(root : String) : Nil
    write_source(root, ".mochi-lint.yml", <<-YAML)
      version: 1
      include:
        - "lib/**/*.rb"
      exclude:
        - "lib/ignored/**"
      rules:
        correctness/unknown-handler: error
        correctness/timer-callback: error
        correctness/child-props: error
        correctness/event-payload: error
        components/prop-write: warning
        metrics/method-length:
          severity: warning
          max: 3
        metrics/nesting-depth:
          severity: warning
          max: 1
        metrics/component-methods:
          severity: warning
          max: 4
        accessibility/control-name: warning
        accessibility/keyboard-activation: warning
        templates/unstable-key: warning
        migration/css-timer: warning
        money/float-to-minor-units: warning
      YAML

    write_source(root, "lib/ChildCard.rb", <<-RUBY)
      class ChildCard
        @tag_name = "child-card"
        prop :label, String, required: true
        prop :count, Integer, default: 0
        event :selected, id: Integer

        def html
          %Q{<button onclick="{choose}">{@label}</button>}
        end

        def choose
          emit :selected, id: "seven"
        end
      end
      RUBY

    write_source(root, "lib/Panel.rb", <<-RUBY)
      class Panel
        @tag_name = "panel"
        prop :title, String, default: "panel"
        @label
        @child_label

        def initialize
          @title = "configured"
          @label = "panel"
          @child_label = "child"
        end

        def html
          %Q{
            <child-card label="{@label}" count="nope"></child-card>
            <button onclick="{missing_handler}">Open</button>
            <div role="button" onclick="{toggle}"></div>
          }
        end

        def toggle
          @label = "toggled"
        end

        def long_method
          value = 1
          value = value + 1
          value = value + 1
          value = value + 1
          value = value + 1
          value = value + 1
        end

        def nested(flag)
          if flag
            if flag
              @label = "nested"
            end
          end
        end

        def schedule
          Mochi.after(10, :missing_timer)
        end

        def price(total)
          MochiFormat.currency((total * 100).round, "USD")
        end
      end
      RUBY

    write_source(root, "lib/ListPanel.rb", <<-RUBY)
      class ListPanel
        @tag_name = "list-panel"
        @rows

        def initialize
          @rows = [{"id" => "a"}, {"id" => "b"}]
        end

        def html
          %Q{
            <ul>
              <!-- mochi-lint: disable-next templates/unstable-key -- index identity has separate coverage below -->
              {each @rows as row, index, key: index}
                <li>{row["id"]}</li>
              {end}
              {each ["b", "a"].sort as item}
                <li>{item}</li>
              {end}
            </ul>
          }
        end

        # mochi-lint: disable-next metrics/method-length -- stale suppression fixture
        def short
          "ok"
        end
      end
      RUBY

    write_source(root, "lib/TickPanel.rb", <<-RUBY)
      class TickPanel
        @tag_name = "tick-panel"
        @phase
        @ticks

        def initialize
          @phase = 0
          @ticks = 0
        end

        def html
          %Q{
            <div hidden class="tick-driver phase-{@phase}" onanimationend="{advance}"></div>
            <span>{@ticks}</span>
          }
        end

        def advance
          @phase = @phase + 1
          @ticks = @ticks + 1
          Mochi.emit("tick")
        end
      end
      RUBY

    write_source(root, "lib/ignored/Broken.rb", <<-RUBY)
      class Broken
        def oops(
      end
      RUBY
  end

  def contract_block(markdown : String, info : String) : String
    marker = "```#{info}\n"
    start = markdown.index(marker)
    raise "missing #{info} block in #{CONTRACT_PATH}" unless start
    content_start = start + marker.size
    finish = markdown.index("```", content_start)
    raise "unterminated #{info} block in #{CONTRACT_PATH}" unless finish
    markdown[content_start...finish]
  end

  def load_config(root : String, source : String) : Lint::Config
    write_source(root, ".mochi-lint.yml", source)
    Lint::Config.load(root, true, File.join(root, ".mochi-lint.yml"), root)
  end

  def diagnostics_from_json(stdout : String) : Array(JSON::Any)
    parsed = JSON.parse(stdout)
    parsed["schema_version"].as_i.should eq 1
    parsed["diagnostics"].as_a
  end
end

describe "lint integration contract" do
  it "reports configured rule families, honors a suppression, and exposes text and JSON consistently" do
    LintIntegrationSpecSupport.with_project do |root|
      LintIntegrationSpecSupport.write_contract_project(root)

      text_status, text_output, text_error = LintIntegrationSpecSupport.run_lint(root)
      json_status, json_output, json_error = LintIntegrationSpecSupport.run_lint(root, ["--format=json"])

      text_status.should eq 1
      json_status.should eq 1
      text_error.should eq ""
      json_error.should eq ""
      json_output.lstrip.starts_with?('{').should be_true

      diagnostics = LintIntegrationSpecSupport.diagnostics_from_json(json_output)
      rules = diagnostics.map { |diagnostic| diagnostic["rule"].as_s }
      text_lines = text_output.lines.reject(&.empty?)

      text_lines.size.should eq diagnostics.size
      text_lines.each do |line|
        line.should match(/\Alib\/[^:]+:\d+:\d+: (?:error|warning) [a-z]+\/[a-z0-9-]+: /)
      end

      expected = %w[
        accessibility/control-name
        accessibility/keyboard-activation
        components/prop-write
        correctness/child-props
        correctness/event-payload
        correctness/timer-callback
        correctness/unknown-handler
        lint/suppression
        metrics/component-methods
        metrics/method-length
        metrics/nesting-depth
        migration/css-timer
        money/float-to-minor-units
        templates/unstable-key
      ]
      (expected - rules).should be_empty
      rules.should_not contain("ruby/syntax")
      rules.should_not contain("analysis/limitation")
      rules.count("templates/unstable-key").should eq 1
      text_output.should_not contain("ignored/Broken.rb")

      stale = diagnostics.find { |diagnostic| diagnostic["rule"].as_s == "lint/suppression" }.not_nil!
      stale["message"].as_s.should contain("suppression for 'metrics/method-length' does not suppress an enabled diagnostic")

      diagnostics.each do |diagnostic|
        %w[path line column end_line end_column start_byte end_byte severity rule message].each do |field|
          diagnostic[field]?.should_not be_nil
        end
      end
    end
  end

  it "orders diagnostics deterministically and keeps relative locations when a project moves" do
    LintIntegrationSpecSupport.with_project("mochi_lint_contract_a") do |first_root|
      LintIntegrationSpecSupport.with_project("mochi_lint_contract_b") do |second_root|
        LintIntegrationSpecSupport.write_contract_project(first_root)
        LintIntegrationSpecSupport.write_contract_project(second_root)

        first_status, first_output, first_error = LintIntegrationSpecSupport.run_lint(first_root, ["--format=json"])
        repeat_status, repeat_output, repeat_error = LintIntegrationSpecSupport.run_lint(first_root, ["--format=json"])
        second_status, second_output, second_error = LintIntegrationSpecSupport.run_lint(second_root, ["--format=json"])

        first_status.should eq 1
        repeat_status.should eq 1
        second_status.should eq 1
        first_error.should eq ""
        repeat_error.should eq ""
        second_error.should eq ""
        repeat_output.should eq first_output
        second_output.should eq first_output
        first_output.should_not contain(first_root)
        second_output.should_not contain(second_root)

        diagnostics = LintIntegrationSpecSupport.diagnostics_from_json(first_output)
        keys = diagnostics.map do |diagnostic|
          {
            diagnostic["path"].as_s,
            diagnostic["start_byte"].as_i,
            diagnostic["rule"].as_s,
            diagnostic["message"].as_s,
            diagnostic["end_byte"].as_i,
            diagnostic["severity"].as_s,
            diagnostic["suggestion"]?.try(&.as_s) || "",
          }
        end
        keys.should eq keys.sort
      end
    end
  end

  it "lints every documented generic example cleanly" do
    contract = File.read(LintIntegrationSpecSupport::CONTRACT_PATH)
    marker = "```ruby mochi-lint-example\n"
    examples = [] of String
    offset = 0
    while start = contract.index(marker, offset)
      content_start = start + marker.size
      finish = contract.index("```", content_start)
      break unless finish
      examples << contract[content_start...finish]
      offset = finish + 3
    end
    examples.size.should eq 3

    LintIntegrationSpecSupport.with_project do |root|
      LintIntegrationSpecSupport.write_source(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        rules:
          templates/unstable-key: warning
          migration/css-timer: warning
          money/float-to-minor-units: warning
        YAML
      LintIntegrationSpecSupport.write_source(root, "lib/DocumentedExamples.rb", examples.join("\n"))

      status, stdout, stderr = LintIntegrationSpecSupport.run_lint(root)
      status.should eq 0
      stdout.should eq ""
      stderr.should eq ""
    end
  end

  it "loads every shipped documentation configuration through the real parser" do
    contract = File.read(LintIntegrationSpecSupport::CONTRACT_PATH)

    LintIntegrationSpecSupport.with_project do |root|
      standard = LintIntegrationSpecSupport.load_config(
        root,
        LintIntegrationSpecSupport.contract_block(contract, "yaml mochi-lint-config"),
      )
      standard.include_globs.should eq Lint::Config::DEFAULT_INCLUDE
      standard.exclude_globs.should be_empty
      Lint::RuleRegistry::RULES.each do |id, definition|
        settings = standard.settings_for(id)
        settings.level.should eq definition.default_level
        settings.options.should eq definition.default_options
      end

      advice = LintIntegrationSpecSupport.load_config(
        root,
        LintIntegrationSpecSupport.contract_block(contract, "yaml mochi-lint-advice"),
      )
      %w[templates/unstable-key migration/css-timer money/float-to-minor-units].each do |id|
        advice.level_for(id).should eq Lint::RuleLevel::Warning
      end
      advice.level_for("metrics/method-length").should eq Lint::RuleLevel::Warning
      advice.settings_for("metrics/method-length")["max"].should eq 60
    end
  end

  it "documents only registered rules and implemented CLI flags" do
    contract = File.read(LintIntegrationSpecSupport::CONTRACT_PATH)

    documented_rules = [] of String
    contract.scan(/^\| `([a-z]+\/[a-z0-9-]+)` \|/m) do |match|
      documented_rules << match[1]
    end
    documented_rules.sort.should eq Lint::RuleRegistry::RULES.keys.sort

    documented_defaults = {} of String => String
    contract.scan(/^\| `([a-z]+\/[a-z0-9-]+)` \| `(error|warning|off)` \|/m) do |match|
      documented_defaults[match[1]] = match[2]
    end
    Lint::RuleRegistry::RULES.each do |id, definition|
      documented_defaults[id]?.should eq definition.default_level.label
    end

    contract.scan(/`([a-z]+\/[a-z0-9-]+)`/) do |match|
      Lint::RuleRegistry[match[1]]?.should_not be_nil
    end

    Lint::RuleRegistry::RULES.each do |id, definition|
      next if definition.options.empty?
      definition.options.each do |name, option|
        contract.should contain("`#{name}: #{option.default_value}`")
      end
    end

    help = IO::Memory.new
    LintRunner.new.run(["--help"], help, IO::Memory.new, Dir.current).should eq 0
    help_text = help.to_s
    contract.scan(/(--[a-z][a-z-]+)/) do |match|
      help_text.should contain(match[1])
    end
    %w[-i -h --input --config --format --help].each do |flag|
      contract.should contain(flag)
    end
  end
end
