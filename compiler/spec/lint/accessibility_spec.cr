require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/accessibility"
require "../../src/tooling/lint_runner"

module LintAccessibilitySpecSupport
  extend self

  def with_project(prefix = "mochi_lint_accessibility", &)
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
      Lint::Rules::Accessibility.diagnostics(project_index)
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

describe Lint::Rules::Accessibility do
  it "reports unnamed native controls and accepts static name sources" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/NativeControls.rb", <<-RUBY)
        class NativeControls
          @tag_name = "native-controls"
          @label = "Label"

          def html
            %Q{
              <button></button>
              <a href="/save"></a>
              <button aria-label="Save"></button>
              <a href="/help">Help</a>
              <button aria-labelledby="label-id"></button>
              <span id="label-id">Named</span>
              <button><img alt="Icon"></button>
              <button><img alt=""></button>
              <button>{@label}</button>
              <button>{Mochi.raw(@label)}</button>
              <button>   </button>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.rule(
        LintAccessibilitySpecSupport.diagnostics(root),
        "accessibility/control-name",
      )

      found.map(&.start_line).should eq [7, 8, 14, 17]
      found[0].message.should contain("<button> has no accessible name")
      found[1].message.should contain("<a href> has no accessible name")
      found[2].message.should contain("<button> has no accessible name")
      found[3].message.should contain("<button> has no accessible name")
      found.each do |diagnostic|
        diagnostic.suggestion.not_nil!.should contain("aria-labelledby")
      end
    end
  end

  it "requires local keyboard activation for custom button roles" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/RoleControls.rb", <<-RUBY)
        class RoleControls
          @tag_name = "role-controls"
          @items = []
          @hidden = false
          @role = "button"

          def activate
          end

          def move_keyboard(event)
          end

          def html
            %Q{
              <div role="button" onclick="{activate}">Save</div>
              <div role="button" onclick="{activate}" onkeydown="{move_keyboard($event)}">Save</div>
              <div role="button" onclick.self="{activate}" onkeyup.prevent="{move_keyboard($event)}">Save</div>
              <button role="button" onclick="{activate}">Save</button>
              <div role="button" onclick="{activate}" hidden>Save</div>
              <div role="button" onclick="{activate}" aria-hidden="true">Save</div>
              <div role="button" onclick="{activate}" hidden="{@hidden}">Save</div>
              <div role="{@role}" onclick="{activate}">Save</div>
              <div role="button">Save</div>
              <div role="button" onclick="{activate}"></div>
              <a role="button" onclick="{activate}"></a>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.diagnostics(root)

      keyboard = LintAccessibilitySpecSupport.rule(found, "accessibility/keyboard-activation")
      keyboard.map(&.start_line).should eq [15, 24, 25]
      keyboard[0].message.should contain("has no local onkeydown or onkeyup handler")

      controls = LintAccessibilitySpecSupport.rule(found, "accessibility/control-name")
      controls.map(&.start_line).should eq [24, 25]
      controls[1].message.should contain("<a role=\"button\"> has no accessible name")
    end
  end

  it "requires the keyboard handler on the role element itself" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/DelegatedControls.rb", <<-RUBY)
        class DelegatedControls
          @tag_name = "delegated-controls"

          def activate
          end

          def move_keyboard(event)
          end

          def html
            %Q{
              <div role="button" onclick="{activate}"><span onkeydown="{move_keyboard($event)}">Save</span></div>
              <div role="button" onclick="{activate}"><span onkeyup="{move_keyboard($event)}">Save</span></div>
              <div role="button" onclick="{activate}" onkeydown="{move_keyboard($event)}"><span>Save</span></div>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.rule(
        LintAccessibilitySpecSupport.diagnostics(root),
        "accessibility/keyboard-activation",
      )

      found.map(&.start_line).should eq [12, 13]
    end
  end

  it "scans conditional branches and nested rows with distinct source ranges" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/RowControls.rb", <<-RUBY)
        class RowControls
          @tag_name = "row-controls"
          @items = []

          def html
            %Q{
              <ul>
                {each @items as item}
                  <li>
                    {if item["ready"]}
                      <button></button>
                    {else}
                      <button></button>
                    {end}
                    {each item["tags"] as tag}
                      <button></button>
                    {end}
                    <div><button></button><button></button></div>
                    <button>{item["label"]}</button>
                  </li>
                {end}
              </ul>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.rule(
        LintAccessibilitySpecSupport.diagnostics(root),
        "accessibility/control-name",
      )

      found.map(&.start_line).should eq [11, 13, 16, 18, 18]
      found[3].start_column.should_not eq found[4].start_column
    end
  end

  it "treats dynamic text and unresolved references as unknown, but hidden text as absent" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/DynamicControls.rb", <<-RUBY)
        class DynamicControls
          @tag_name = "dynamic-controls"
          @label = "Label"

          def html
            %Q{
              <button>{@label}</button>
              <button>{Mochi.raw(@label)}</button>
              <button>{Mochi.raw("<span><button></button></span>")}</button>
              <a href="{@url}">{@label}</a>
              <button><child-icon></child-icon></button>
              <button aria-label="{@label}"></button>
              <button aria-labelledby="missing"></button>
              <button><span>{@label}</span></button>
              <button><span hidden>Hidden</span></button>
              <button><span hidden>{@label}</span></button>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.rule(
        LintAccessibilitySpecSupport.diagnostics(root),
        "accessibility/control-name",
      )

      found.map(&.start_line).should eq [15, 16]
    end
  end

  it "ignores comments and keeps quoted angle brackets out of the element tree" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/QuotedControls.rb", <<-RUBY)
        class QuotedControls
          @tag_name = "quoted-controls"

          def html
            %Q{
              <button title="a > b"><!-- ignored text --></button>
              <button data-note="1 < 2">Named</button>
              <template><button></button></template>
              <script><button></button></script>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.rule(
        LintAccessibilitySpecSupport.diagnostics(root),
        "accessibility/control-name",
      )

      found.map(&.start_line).should eq [6]
    end
  end

  it "uses svg titles and image alt text while leaving decorative svg unnamed" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/IconControls.rb", <<-RUBY)
        class IconControls
          @tag_name = "icon-controls"

          def go
          end

          def move_keyboard(event)
          end

          def html
            %Q{
              <button><svg><path d="M0 0"/></svg></button>
              <button><svg role="img" aria-label="Chart"></svg></button>
              <button><svg><title>Chart</title><path d="M0 0"/></svg></button>
              <svg role="button" onclick="{go}"><title>Go</title></svg>
              <svg role="button" onclick="{go}" onkeydown="{move_keyboard($event)}"><title>Go</title></svg>
              <svg role="button" onclick="{go}"></svg>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.diagnostics(root)

      controls = LintAccessibilitySpecSupport.rule(found, "accessibility/control-name")
      controls.map(&.start_line).should eq [12, 17]

      keyboard = LintAccessibilitySpecSupport.rule(found, "accessibility/keyboard-activation")
      keyboard.map(&.start_line).should eq [15, 17]
    end
  end

  it "skips hidden and dynamically hidden controls" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/HiddenControls.rb", <<-RUBY)
        class HiddenControls
          @tag_name = "hidden-controls"
          @hidden = false

          def activate
          end

          def html
            %Q{
              <button hidden></button>
              <div hidden><button></button></div>
              <div aria-hidden="true"><button></button></div>
              <button hidden="false"></button>
              <div hidden="{@hidden}"><button></button></div>
              <button aria-hidden="{@hidden}"></button>
              <div inert><div role="button" onclick="{activate}">Save</div></div>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.diagnostics(root)

      LintAccessibilitySpecSupport.rule(found, "accessibility/control-name")
        .map(&.start_line)
        .should eq [13]
      LintAccessibilitySpecSupport.rule(found, "accessibility/keyboard-activation")
        .should be_empty
    end
  end

  it "reports nothing when both rules are off" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/OffControls.rb", <<-RUBY)
        class OffControls
          @tag_name = "off-controls"

          def activate
          end

          def html
            %Q{
              <button></button>
              <div role="button" onclick="{activate}"></div>
            }
          end
        end
        RUBY

      found = LintAccessibilitySpecSupport.diagnostics(
        root,
        {
          "accessibility/control-name"        => "off",
          "accessibility/keyboard-activation" => "off",
        },
      )

      found.should be_empty
    end
  end

  it "reports accessibility warnings through the lint CLI" do
    LintAccessibilitySpecSupport.with_project do |root|
      LintAccessibilitySpecSupport.write(root, "lib/CliControls.rb", <<-RUBY)
        class CliControls
          @tag_name = "cli-controls"

          def activate
          end

          def html
            %Q{
              <button></button>
              <div role="button" onclick="{activate}">Save</div>
            }
          end
        end
        RUBY

      status, stdout, stderr = LintAccessibilitySpecSupport.run_lint(root)

      status.should eq 1
      stderr.should be_empty
      stdout.should contain("warning accessibility/control-name:")
      stdout.should contain("warning accessibility/keyboard-activation:")
      stdout.should contain("lib/CliControls.rb:9:")
      stdout.should contain("lib/CliControls.rb:10:")
    end
  end
end
