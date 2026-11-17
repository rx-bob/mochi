require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/template_element_indent"
require "../../src/lint/suppressions"
require "../../src/tooling/lint_runner"

module LintTemplateElementIndentSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_template_element_indent", &)
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
      raw = Lint::Rules::TemplateElementIndent.diagnostics(index)
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

describe Lint::Rules::TemplateElementIndent do
  it "reports closing tags that do not align with their opening tags" do
    LintTemplateElementIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class Cluster
          @tag_name = "cluster"

          def html
            %Q{
              <header>
                <div class="heading">
                  <span>Cluster</span>
                </div></header>
              <div class="refresh">
                <button>
                  Refresh
                </button>
              </div>
            }
          end
        end
        RUBY
      LintTemplateElementIndentSpecSupport.write(root, "lib/Cluster.rb", source)

      rules = {"style/template-element-indent" => "warning"}
      diagnostics = LintTemplateElementIndentSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 9
      diagnostic.rule.should eq Lint::Rules::TemplateElementIndent::RULE
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.message.should eq "closing tag indentation does not match its opening tag"
      diagnostic.suggestion.should eq "Align </header> with <header>."
    end
  end

  it "accepts aligned, inline, void, and self-closing elements" do
    LintTemplateElementIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class Cluster
          @tag_name = "cluster"

          def html
            %Q{
              <header>
                <div>
                  <span>Inline</span>
                  Wrapped <span>text
                    more</span>
                </div>
              </header>
              <br>
              <img />
            }
          end
        end
        RUBY
      LintTemplateElementIndentSpecSupport.write(root, "lib/Cluster.rb", source)

      rules = {"style/template-element-indent" => "warning"}
      LintTemplateElementIndentSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "checks custom component tags" do
    LintTemplateElementIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class Cluster
          @tag_name = "cluster"

          def html
            %Q{
              <child-badge>
                Badge
                </child-badge>
            }
          end
        end
        RUBY
      LintTemplateElementIndentSpecSupport.write(root, "lib/Cluster.rb", source)

      rules = {"style/template-element-indent" => "warning"}
      diagnostics = LintTemplateElementIndentSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.suggestion.should eq "Align </child-badge> with <child-badge>."
    end
  end

  it "supports a template suppression directive" do
    LintTemplateElementIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class Cluster
          @tag_name = "cluster"

          def html
            %Q{
              <!-- mochi-lint: disable-next style/template-element-indent -- inline probe fixture -->
              <header>
                <span>Cluster</span>
                </header>
            }
          end
        end
        RUBY
      LintTemplateElementIndentSpecSupport.write(root, "lib/Cluster.rb", source)

      rules = {"style/template-element-indent" => "warning"}
      LintTemplateElementIndentSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "is on by default and can be disabled" do
    LintTemplateElementIndentSpecSupport.with_project do |root|
      source = <<-RUBY
        class Cluster
          @tag_name = "cluster"

          def html
            %Q{
              <header>
                <span>Cluster</span>
                </header>
            }
          end
        end
        RUBY
      LintTemplateElementIndentSpecSupport.write(root, "lib/Cluster.rb", source)

      status, output, error = LintTemplateElementIndentSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Cluster.rb:8:9: warning style/template-element-indent: closing tag indentation does not match its opening tag"
      error.should be_empty

      LintTemplateElementIndentSpecSupport.config(root, {"style/template-element-indent" => "off"})
      status, output, error = LintTemplateElementIndentSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
