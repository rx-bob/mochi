require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/template_nesting_indent"
require "../../src/lint/suppressions"
require "../../src/tooling/lint_runner"

module LintTemplateNestingIndentSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_template_nesting_indent", &)
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
      raw = Lint::Rules::TemplateNestingIndent.diagnostics(index)
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

describe Lint::Rules::TemplateNestingIndent do
  it "reports a block marker at the same indentation as its parent element" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"
          @hosts = []

          def html
            %Q{
              <div class="host-list">
              {each @hosts as host}
                <article>{host["label"]}</article>
              {end}
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      diagnostics = LintTemplateNestingIndentSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 8
      diagnostic.rule.should eq Lint::Rules::TemplateNestingIndent::RULE
      diagnostic.message.should eq "template block marker is not indented relative to its parent"
      diagnostic.suggestion.should eq "Indent the block marker one level deeper than its parent."
    end
  end

  it "accepts block markers and child elements indented under their parents" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"
          @hosts = []

          def html
            %Q{
              <div class="host-list">
                {each @hosts as host}
                  <article>{host["label"]}</article>
                {end}
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      LintTemplateNestingIndentSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "uses the parent line indentation when the parent opens mid-line" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"

          def html
            %Q{
              <div class="host-list">
                <article><div class="host-heading">
                    <span>Host</span>
                </div></article>
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      LintTemplateNestingIndentSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "reports a child element at the same indentation as its parent element" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"

          def html
            %Q{
              <div class="host-list">
              <article>Host</article>
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      diagnostics = LintTemplateNestingIndentSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 7
      diagnostic.message.should eq "child element is not indented relative to its parent element"
      diagnostic.suggestion.should eq "Indent <article> one level deeper than its parent."
    end
  end

  it "uses the nearest block as the parent when no child element intervenes" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"
          @hosts = []

          def html
            %Q{
              {each @hosts as host}
              {if host["id"]}
                <span>{host["id"]}</span>
              {end}
              {end}
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      diagnostics = LintTemplateNestingIndentSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.start_line.should eq 8
    end
  end

  it "supports a template suppression directive" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"

          def html
            %Q{
              <div class="host-list">
              <!-- mochi-lint: disable-next style/template-nesting-indent -- flattened fixture -->
              <article>Host</article>
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      rules = {"style/template-nesting-indent" => "warning"}
      LintTemplateNestingIndentSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "is on by default and can be disabled" do
    LintTemplateNestingIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class HostList
          @tag_name = "host-list"

          def html
            %Q{
              <div class="host-list">
              <article>Host</article>
              </div>
            }
          end
        end
        RUBY
      LintTemplateNestingIndentSpecSupport.write(root, "lib/HostList.rb", source)

      status, output, error = LintTemplateNestingIndentSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/HostList.rb:7:7: warning style/template-nesting-indent: child element is not indented relative to its parent element"
      error.should be_empty

      LintTemplateNestingIndentSpecSupport.config(root, {"style/template-nesting-indent" => "off"})
      status, output, error = LintTemplateNestingIndentSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
