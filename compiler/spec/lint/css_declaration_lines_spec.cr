require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/css_declaration_lines"
require "../../src/lint/suppressions"
require "../../src/tooling/lint_runner"

module LintCssDeclarationLinesSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_css_lines", &)
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
      raw = Lint::Rules::CssDeclarationLines.diagnostics(index)
      Lint::Suppressions.apply(index, raw)
    ensure
      index.close
    end
  end

  def run_lint(root : String, args = [] of String) : Tuple(Int32, String, String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = LintRunner.new.run(["-i", root] + args, output, error)
    {status, output.to_s, error.to_s}
  end
end

describe Lint::Rules::CssDeclarationLines do
  it "reports packed declarations and allows one declaration per line" do
    LintCssDeclarationLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def css
            %Q{
              .card { display: flex; gap: 12px; }
              .badge { display: block; }
              .packed { color: red; background: blue; }
              .split { display: flex;
                gap: 12px; }
            }
          end
        end
        RUBY
      LintCssDeclarationLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/css-declaration-lines" => "warning"}
      diagnostics = LintCssDeclarationLinesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 2
      diagnostics.map(&.start_line).should eq [4, 6]
      diagnostics.each do |diagnostic|
        diagnostic.rule.should eq Lint::Rules::CssDeclarationLines::RULE
        diagnostic.severity.should eq Lint::Severity::Warning
        diagnostic.message.should eq "line has 2 CSS declarations; maximum is 1"
        diagnostic.suggestion.should eq "Put each CSS declaration on its own line."
      end
    end
  end

  it "ignores semicolons in strings, URLs, comments, imports, and interpolation" do
    LintCssDeclarationLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def css
            %Q{
              @import "one.css";
              @import "two.css";
              .card { content: "a;b"; }
              .icon { background: url("data:image/svg+xml;charset=utf-8,<svg></svg>"); }
              /* color: red;
                 gap: 2px; */
              .pick { color: \#{pick("red;blue")}; }
              .plain { color: red }
            }
          end
        end
        RUBY
      LintCssDeclarationLinesSpecSupport.write(root, "lib/Widget.rb", source)

      rules = {"style/css-declaration-lines" => "warning"}
      LintCssDeclarationLinesSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "is on by default and can be disabled" do
    LintCssDeclarationLinesSpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def css
            %Q{
              .card { display: flex; gap: 12px; }
            }
          end
        end
        RUBY
      LintCssDeclarationLinesSpecSupport.write(root, "lib/Widget.rb", source)

      status, output, error = LintCssDeclarationLinesSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/Widget.rb:4:1: warning style/css-declaration-lines: line has 2 CSS declarations; maximum is 1"
      error.should be_empty

      LintCssDeclarationLinesSpecSupport.config(root, {"style/css-declaration-lines" => "off"})
      status, output, error = LintCssDeclarationLinesSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
