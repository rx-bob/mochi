require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/rules/method_length"
require "../../src/lint/rules/nesting_depth"
require "../../src/tooling/lint_runner"

module LintComplexitySpecSupport
  extend self

  def with_project(prefix = "mochi_lint_complexity", &)
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
      Lint::Diagnostics.sort(
        Lint::Rules::MethodLength.diagnostics(index) +
        Lint::Rules::NestingDepth.diagnostics(index)
      )
    ensure
      index.close
    end
  end

  def rule(diagnostics : Array(Lint::Diagnostic), id : String) : Array(Lint::Diagnostic)
    diagnostics.select { |diagnostic| diagnostic.rule == id }
  end

  def run_lint(root : String, args = [] of String) : Tuple(Int32, String, String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = LintRunner.new.run(["-i", root] + args, output, error)
    {status, output.to_s, error.to_s}
  end

  def long_method_source(lines : Int32, singleton = false, line_ending = "\n") : String
    String.build do |io|
      io << "class Widget" << line_ending
      io << "  def " << (singleton ? "self.long" : "long") << line_ending
      lines.times { |index| io << "    value_#{index} = #{index}" << line_ending }
      io << "  end" << line_ending
      io << "end" << line_ending
    end
  end

  def nested_source(depth : Int32) : String
    String.build do |io|
      io << "class Widget\n  def nested\n"
      depth.times { |index| io << "    " * (index + 1) << "if condition_#{index}\n" }
      io << "    " * (depth + 1) << "work\n"
      depth.times { |index| io << "    " * (depth - index) << "end\n" }
      io << "  end\nend\n"
    end
  end
end

describe Lint::Rules::MethodLength do
  it "passes exactly 60 body lines and reports 61 with the observed count" do
    LintComplexitySpecSupport.with_project do |root|
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(60))
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root), Lint::Rules::MethodLength::RULE)
      diagnostics.should be_empty

      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(61))
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.start_line.should eq 2
      diagnostic.message.should eq "method 'long' has 61 body lines; maximum is 60"
    end
  end

  it "counts comment-only method bodies and skips empty methods" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def comments
            # one
            # two
            # three
          end

          def empty
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "{severity: warning, max: 3}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty

      rules = {"metrics/method-length" => "{severity: warning, max: 2}", "metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'comments' has 3 body lines; maximum is 2"
    end
  end

  it "uses a configured positive max and can be turned off" do
    LintComplexitySpecSupport.with_project do |root|
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(3))
      rules = {"metrics/method-length" => "{severity: warning, max: 3}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty

      rules = {"metrics/method-length" => "{severity: warning, max: 2}", "metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'long' has 3 body lines; maximum is 2"

      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty
    end
  end

  it "counts blank and comment lines between statements" do
    LintComplexitySpecSupport.with_project do |root|
      source = String.build do |io|
        io << "class Widget\n  def long\n    work\n    # keep the explanation with the method\n"
        57.times { io << "\n" }
        io << "    finish\n  end\nend\n"
      end
      rules = {"metrics/method-length" => "{severity: warning, max: 60}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty

      source = String.build do |io|
        io << "class Widget\n  def long\n    work\n    # keep the explanation with the method\n"
        58.times { io << "\n" }
        io << "    finish\n  end\nend\n"
      end
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'long' has 61 body lines; maximum is 60"
    end
  end

  it "counts leading and trailing blank and comment lines without counting the signature" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def long(
            value
          )
            # leading

            work value

            # trailing

          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "{severity: warning, max: 6}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty

      rules = {"metrics/method-length" => "{severity: warning, max: 5}", "metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'long' has 6 body lines; maximum is 5"
    end
  end

  it "counts a multiline template literal once and keeps surrounding Ruby lines" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def html
            %Q{
              <div>
                {if @expanded}
                  <span>Details</span>
                {end}
              </div>
            }
            compute
            finish
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "{severity: warning, max: 3}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty

      rules = {"metrics/method-length" => "{severity: warning, max: 2}", "metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'html' has 3 body lines; maximum is 2"
    end
  end

  it "counts heredocs once and ignores def and end text inside literals" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def css
            <<~CSS
              .panel {
                color: red;
              }
            CSS
          end

          def literal
            text = %Q{
              def fake
                <div>end</div>
              end
            }
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "{severity: warning, max: 1}", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE).should be_empty
    end
  end

  it "counts a body that starts on the signature line" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def inline; %Q{
            <div>
          }
          finish
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "{severity: warning, max: 1}", "metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'inline' has 2 body lines; maximum is 1"
    end
  end

  it "reports singleton methods and keeps CRLF line boundaries exact" do
    LintComplexitySpecSupport.with_project do |root|
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(61, singleton: true, line_ending: "\r\n"))
      rules = {"metrics/nesting-depth" => "off"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::MethodLength::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'long' has 61 body lines; maximum is 60"
    end
  end
end

describe Lint::Rules::NestingDepth do
  it "passes depth 4 and reports the first node at depth 5" do
    LintComplexitySpecSupport.with_project do |root|
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.nested_source(4))
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE).should be_empty

      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.nested_source(5))
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.start_line.should eq 7
      diagnostic.message.should eq "method 'nested' reaches nesting depth 5; maximum is 4"
    end
  end

  it "does not add levels for elsif, else, when, or in sibling arms" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def branches(value)
            if first
              one
            elsif second
              if third
                if fourth
                  if fifth
                    work
                  end
                end
              end
            else
              two
            end

            case value
            in Integer
              if alpha
                if beta
                  if gamma
                    work
                  end
                end
              end
            else
              two
            end

            case value
            when "fallback"
              if alpha
                if beta
                  if gamma
                    work
                  end
                end
              end
            else
              two
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE).should be_empty
    end
  end

  it "reports depth 5 reached inside an elsif arm" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def deeper(value)
            if first
              one
            elsif second
              if third
                if fourth
                  if fifth
                    if sixth
                      work
                    end
                  end
                end
              end
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'deeper' reaches nesting depth 5; maximum is 4"
    end
  end

  it "counts ordinary blocks and modifier conditionals as one level each" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def blocks(rows)
            rows.each do |row|
              if row
                rows.each do |item|
                  if item
                    work
                  end
                end
              end
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE).should be_empty

      source = source.sub(/\bwork\n/, "work if flag\n")
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'blocks' reaches nesting depth 5; maximum is 4"
    end
  end

  it "ignores template and string literals while counting real control flow" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def render(rows)
            %Q{
              {if @expanded}
                {each rows as row}
                  <span>{row}</span>
                {end}
              {end}
            }
            text = <<~TEXT
              if condition
                while other
                  for item in items
                    work
                  end
                end
              end
            TEXT
            if first
              while second
                for item in rows
                  begin
                    work if ready
                  rescue
                    recover
                  end
                end
              end
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE).should be_empty
    end
  end

  it "counts loop, rescue, ternary, and singleton levels once per method" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def conditional(item)
            while first
              until second
                for row in rows
                  value = item ? 1 : 2
                end
              end
            end
          end

          def rescued
            while first
              until second
                for row in rows
                  begin
                    work
                  rescue
                    recover
                  end
                end
              end
            end
          end

          def self.singleton
            while first
              until second
                for row in rows
                  if row
                    work
                  end
                end
              end
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 3}"}
      diagnostics = LintComplexitySpecSupport.rule(
        LintComplexitySpecSupport.diagnostics(root, rules),
        Lint::Rules::NestingDepth::RULE,
      )
      diagnostics.size.should eq 3
      diagnostics.map(&.message).should eq [
        "method 'conditional' reaches nesting depth 4; maximum is 3",
        "method 'rescued' reaches nesting depth 4; maximum is 3",
        "method 'singleton' reaches nesting depth 4; maximum is 3",
      ]
    end
  end

  it "counts a guard modifier at its nesting level" do
    LintComplexitySpecSupport.with_project do |root|
      source = <<-RUBY
        class Widget
          def guarded(rows)
            while first
              until second
                for row in rows
                  return unless row
                  work
                end
              end
            end
          end
        end
        RUBY
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", source)
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 4}"}
      LintComplexitySpecSupport.rule(
        LintComplexitySpecSupport.diagnostics(root, rules),
        Lint::Rules::NestingDepth::RULE,
      ).should be_empty

      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 3}"}
      diagnostics = LintComplexitySpecSupport.rule(
        LintComplexitySpecSupport.diagnostics(root, rules),
        Lint::Rules::NestingDepth::RULE,
      )
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'guarded' reaches nesting depth 4; maximum is 3"
    end
  end

  it "uses a configured max and can be turned off" do
    LintComplexitySpecSupport.with_project do |root|
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.nested_source(3))
      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "{severity: warning, max: 2}"}
      diagnostics = LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "method 'nested' reaches nesting depth 3; maximum is 2"

      rules = {"metrics/method-length" => "off", "metrics/nesting-depth" => "off"}
      LintComplexitySpecSupport.rule(LintComplexitySpecSupport.diagnostics(root, rules), Lint::Rules::NestingDepth::RULE).should be_empty
    end
  end
end

describe LintRunner do
  it "fails the command for a method-length warning and passes when the body is within the limit" do
    LintComplexitySpecSupport.with_project do |root|
      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(61))
      status, output, error = LintComplexitySpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "metrics/method-length: method 'long' has 61 body lines; maximum is 60"
      error.should be_empty

      LintComplexitySpecSupport.write(root, "lib/Widget.rb", LintComplexitySpecSupport.long_method_source(60))
      status, output, error = LintComplexitySpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
