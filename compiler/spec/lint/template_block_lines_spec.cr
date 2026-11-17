require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/template_block_lines"
require "../../src/lint/suppressions"
require "../../src/tooling/lint_runner"

module LintTemplateBlockLinesSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_template_blocks", &)
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
      raw = Lint::Rules::TemplateBlockLines.diagnostics(index)
      Lint::Suppressions.apply(index, raw)
    ensure
      index.close
    end
  end

  def run_lint(root : String) : Tuple(Int32, String, String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = LintRunner.new.run(["-i", root], output, error)
    {status, output.to_s, error.to_s}
  end
end

describe Lint::Rules::TemplateBlockLines do
  it "reports if, unless, and each blocks that share a line with their body" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false
          @rows = []

          def html
            %Q{
              {if @open}<p>Open</p>{end}
              {unless @open}<p>Closed</p>{end}
              {each @rows as row}<p>{row["name"]}</p>{end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 3
      diagnostics.map(&.start_line).should eq [8, 9, 10]
      diagnostics.each do |diagnostic|
        diagnostic.rule.should eq Lint::Rules::TemplateBlockLines::RULE
        diagnostic.severity.should eq Lint::Severity::Warning
        diagnostic.message.should eq "template block shares a line with block content"
        diagnostic.suggestion.should eq "Put the opening expression, block body, and closing {end} on separate lines."
      end
    end
  end

  it "accepts blocks whose opening and closing expressions are on separate lines" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false
          @rows = []

          def html
            %Q{
              {if @open}
                <p>Open</p>
              {end}
              {unless @open}
                <p>Closed</p>
              {end}
              {each @rows as row}
                <p>{row["name"]}</p>
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      LintTemplateBlockLinesSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "rejects body content on the opening line even when end is on its own line" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              {if @open}<p>Open</p>
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.start_line.should eq 7
    end
  end

  it "rejects content sharing the closing line with end" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              <th>
                {if @open}
                  <p>Open</p>
                {end}</th>
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.start_line.should eq 10
    end
  end

  it "rejects branch markers that share a line with branch content" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              {if @open}
                <p>Open</p>
              {else}<p>Closed</p>
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.start_line.should eq 9
    end
  end

  it "rejects block body that is not indented past its opening expression" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              {if @open}
              <p>Open</p>
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 8
      diagnostic.message.should eq "template block body is not indented relative to its marker"
      diagnostic.suggestion.should eq "Indent the block body one level deeper than the opening expression."
    end
  end

  it "rejects closing end that is not aligned with the opening expression" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              {if @open}
                <p>Open</p>
                {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 9
      diagnostic.message.should eq "template block marker indentation does not match its opening expression"
      diagnostic.suggestion.should eq "Align the block marker with the opening expression."
    end
  end

  it "rejects else and elsif markers that are not aligned with the opening expression" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false
          @ready = false

          def html
            %Q{
              {if @open}
                <p>Open</p>
                {elsif @ready}
                <p>Ready</p>
                {else}
                <p>Closed</p>
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 2
      diagnostics.map(&.start_line).should eq [10, 12]
      diagnostics.each do |diagnostic|
        diagnostic.message.should eq "template block marker indentation does not match its opening expression"
      end
    end
  end

  it "ignores blocks inside attribute values and HTML comments" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              <p class="{if @open}open{end}">Status</p>
              <p class="{unless @open}closed{end}">Status</p>
              <ul>
                {each [1, 2] as item}
                  <li>{item}</li>
                {end}
              </ul>
              <!-- {if @open}<p>Commented</p>{end} -->
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      LintTemplateBlockLinesSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "matches nested blocks by their own end" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false
          @nested = false
          @rows = []

          def html
            %Q{
              {if @open}
                {if @nested}<span>Nested</span>{end}
                {each @rows as row}
                  <p>{row["name"]}</p>
                {end}
              {end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      diagnostics = LintTemplateBlockLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.start_line.should eq 10
    end
  end

  it "supports a template suppression directive" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              <!-- mochi-lint: disable-next style/template-block-lines -- inline probe fixture -->
              {if @open}<p>Open</p>{end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/template-block-lines" => "warning"}
      LintTemplateBlockLinesSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "is on by default and can be disabled" do
    LintTemplateBlockLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          @tag_name = "widget"
          @open = false

          def html
            %Q{
              {if @open}<p>Open</p>{end}
            }
          end
        end
        RUBY
      LintTemplateBlockLinesSpecSupport.write(root, "lib/Widget.rb", source)

      status, output, error = LintTemplateBlockLinesSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:7:7: warning style/template-block-lines: template block shares a line with block content"
      error.should be_empty

      LintTemplateBlockLinesSpecSupport.config(root, {"style/template-block-lines" => "off"})
      status, output, error = LintTemplateBlockLinesSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
