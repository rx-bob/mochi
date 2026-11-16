require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/child_props"
require "../../src/tooling/lint_runner"

module LintChildPropsSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_child_props", &)
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
      Lint::Rules::ChildProps.diagnostics(project_index)
    ensure
      project_index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end
end

describe Lint::Rules::ChildProps do
  it "reports a missing required prop and a literal type mismatch at the parent tag" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildRow.rb", <<-RUBY)
        class ChildRow
          @tag_name = "child-row"
          prop :id, Integer, required: true
          prop :count, Integer

          def html
            %Q{<p>{@id}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentList.rb", <<-RUBY)
        class ParentList
          @tag_name = "parent-list"

          def html
            %Q{
              <child-row count="2"></child-row>
              <child-row id="1" count="many"></child-row>
            }
          end
        end
        RUBY

      found = LintChildPropsSpecSupport.rule(LintChildPropsSpecSupport.diagnostics(root), "correctness/child-props")

      found.size.should eq 2
      missing = found.first
      missing.message.should contain("required prop 'id'")
      missing.message.should contain("<child-row>")
      missing.message.should contain("lib/ChildRow.rb:3")
      missing.suggestion.not_nil!.should contain("id=")
      missing.start_line.should eq 6

      mismatch = found.last
      mismatch.message.should contain("prop 'count'")
      mismatch.message.should contain("expects an Integer")
      mismatch.message.should contain("\"many\"")
      mismatch.message.should contain("lib/ChildRow.rb:4")
      mismatch.start_line.should eq 7
    end
  end

  it "accepts every declared prop type inside its documented literal contract" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :label, String, required: true
          prop :count, Integer
          prop :ratio, Float
          prop :enabled, Boolean
          prop :rows, Array
          prop :meta, Hash

          def html
            %Q{<p>{@label}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <child-card label="" count="0" ratio=".5" enabled rows="[1,2]" meta='{"a":1}'></child-card>
              <child-card label="text" count="9223372036854775807" ratio="Infinity" enabled="false" rows="[]" meta='{}'></child-card>
              <child-card label="text" count="-9223372036854775808" ratio="NaN" enabled="true" rows="[1, [2]]" meta='{"nested": {"ok": true}}'></child-card>
              <child-card label="text" ratio="-Infinity" enabled="false"></child-card>
              <child-card label="entity" count="&#48;" ratio="0.5" enabled="true" rows="[1]" meta='{&quot;a&quot;:1}'></child-card>
            }
          end
        end
        RUBY

      LintChildPropsSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "reports conclusive literal mismatches for every declared prop type" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :label, String, required: true
          prop :count, Integer
          prop :ratio, Float
          prop :enabled, Boolean
          prop :rows, Array
          prop :meta, Hash

          def html
            %Q{<p>{@label}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <child-card label="x" count="1.5" ratio="1e" enabled="yes" rows="{}" meta="[]"></child-card>
            }
          end
        end
        RUBY

      found = LintChildPropsSpecSupport.rule(LintChildPropsSpecSupport.diagnostics(root), "correctness/child-props")

      found.size.should eq 5
      found.map(&.message).join("\n").should contain("prop 'count'")
      found.map(&.message).join("\n").should contain("expects a Float")
      found.map(&.message).join("\n").should contain("expects a Boolean")
      found.map(&.message).join("\n").should contain("expects a JSON array")
      found.map(&.message).join("\n").should contain("expects a JSON object")
    end
  end

  it "checks exact signed 64-bit integer and JSON number boundaries" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :count, Integer
          prop :rows, Array

          def html
            %Q{<p>card</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <child-card count="9223372036854775808"></child-card>
              <child-card count="-9223372036854775809"></child-card>
              <child-card rows="[9007199254740992]"></child-card>
            }
          end
        end
        RUBY

      found = LintChildPropsSpecSupport.rule(LintChildPropsSpecSupport.diagnostics(root), "correctness/child-props")

      found.size.should eq 3
      found[0].message.should contain("outside the signed 64-bit range")
      found[1].message.should contain("outside the signed 64-bit range")
      found[2].message.should contain("outside JavaScript's exact number range")
    end
  end

  it "leaves bindings, conditional values, and attribute hashes statically unknown" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildForm.rb", <<-RUBY)
        class ChildForm
          @tag_name = "child-form"
          prop :title, String, required: true
          prop :enabled, Boolean, required: true
          prop :note, String, default: ""

          def html
            %Q{<p>{@title}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentForm.rb", <<-RUBY)
        class ParentForm
          @tag_name = "parent-form"

          def html
            %Q{
              <child-form title="{@title}" enabled="{@enabled}"></child-form>
              <child-form title="{if @ready}ready{end}" enabled="true"></child-form>
              <child-form class={{ "title" => "spread", "enabled" => "true" }}></child-form>
              <unknown-widget title="{@title}"></unknown-widget>
              <input required="{false}">
            }
          end
        end
        RUBY

      LintChildPropsSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "does not treat quoted doubled braces as an attribute spread" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :id, String, required: true
          prop :title, String

          def html
            %Q{<p>{@id}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <child-card title="{{literal}}"></child-card>
            }
          end
        end
        RUBY

      found = LintChildPropsSpecSupport.rule(LintChildPropsSpecSupport.diagnostics(root), "correctness/child-props")

      found.size.should eq 1
      found.first.message.should contain("required prop 'id'")
    end
  end

  it "maps snake_case props to hyphenated attributes and honors declared Boolean props" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :first_name, String, required: true
          prop :required, Boolean, required: true
          prop :value, String, required: true

          def html
            %Q{<p>{@first_name}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <child-card first-name="Ada" required value="x"></child-card>
              <child-card first_name="Ada" required="false" value="x"></child-card>
              <child-card first_name="Ada" required="{false}" bind:value="@query"></child-card>
            }
          end
        end
        RUBY

      LintChildPropsSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "does not duplicate malformed prop declaration diagnostics" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/BrokenChild.rb", <<-RUBY)
        class BrokenChild
          @tag_name = "broken-child"
          prop :id, Bogus, required: true

          def html
            %Q{<p>broken</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{
              <broken-child></broken-child>
            }
          end
        end
        RUBY

      project_index = LintChildPropsSpecSupport.index(root)
      begin
        Lint::Rules::ChildProps.diagnostics(project_index).should be_empty
        project_index.diagnostics.map(&.message).join("\n").should contain("uses unsupported type Bogus")
      ensure
        project_index.close
      end
    end
  end

  it "honors the rule configuration" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :label, String, required: true

          def html
            %Q{<p>{@label}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{<child-card></child-card>}
          end
        end
        RUBY

      LintChildPropsSpecSupport.diagnostics(root, {"correctness/child-props" => "off"}).should be_empty
    end
  end

  it "reports child prop diagnostics through the lint command" do
    LintChildPropsSpecSupport.with_project do |root|
      LintChildPropsSpecSupport.write(root, "lib/ChildCard.rb", <<-RUBY)
        class ChildCard
          @tag_name = "child-card"
          prop :label, String, required: true

          def html
            %Q{<p>{@label}</p>}
          end
        end
        RUBY
      LintChildPropsSpecSupport.write(root, "lib/ParentCard.rb", <<-RUBY)
        class ParentCard
          @tag_name = "parent-card"

          def html
            %Q{<child-card></child-card>}
          end
        end
        RUBY

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = LintRunner.new.run([] of String, stdout, stderr, root)

      status.should eq 1
      stderr.to_s.should eq ""
      stdout.to_s.should contain("error correctness/child-props:")
    end
  end
end
