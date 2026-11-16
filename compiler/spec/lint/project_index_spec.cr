require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"

module LintProjectIndexSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_index", &)
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

  def config(root : String, includes : Array(String)? = nil) : Lint::Config
    if includes
      write(
        root,
        ".mochi-lint.yml",
        "version: 1\ninclude:\n#{includes.map { |value| "  - \"#{value}\"\n" }.join}",
      )
    end
    Lint::Config.load(root, true, nil, root)
  end

  def build(root : String, includes : Array(String)? = nil) : Tuple(Lint::ProjectIndex, Lint::Config)
    lint_config = config(root, includes)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    {Lint::ProjectIndex.build(files, lint_config), lint_config}
  end
end

describe Lint::ProjectIndex do
  it "indexes sibling, nested, and reopened classes" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Outer.rb", <<-RUBY)
        class Outer
          class Inner
          end
        end

        class Outer
          def reopened
          end
        end

        class Sibling
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        outer = index.class_info("Outer").not_nil!
        outer.declarations.size.should eq 2
        outer.method_names.includes?("reopened").should be_true
        index.class_info("Outer::Inner").not_nil!.qualified_name.should eq "Outer::Inner"
        index.class_info("Sibling").not_nil!.qualified_name.should eq "Sibling"
      ensure
        index.close
      end
    end
  end

  it "resolves local inheritance and mixins from required support files" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/base.rb", <<-RUBY)
        module Shared
          def shared
          end
        end

        class BaseThing
          def base
          end
        end
        RUBY
      LintProjectIndexSpecSupport.write(root, "lib/item.rb", <<-RUBY)
        require_relative "base"

        class ItemThing < BaseThing
          include Shared
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root, ["lib/item.rb"])
      begin
        index.unit("lib/base.rb").not_nil!.target?.should be_false
        item = index.class_info("ItemThing").not_nil!
        index.resolve_superclass(item).not_nil!.qualified_name.should eq "BaseThing"
        index.resolve_mixins(item).map(&.qualified_name).should contain("Shared")
        index.method_status(item, "base").should eq true
        index.method_status(item, "shared").should eq true
        index.method_status(item, "missing").should eq false
      ensure
        index.close
      end
    end
  end

  it "marks unresolved external base classes as open instead of claiming absence" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Child.rb", <<-RUBY)
        class Child < ExternalBase
          def local
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        child = index.class_info("Child").not_nil!
        child.open?.should be_true
        index.method_status(child, "local").should eq true
        index.method_status(child, "external").should be_nil
      ensure
        index.close
      end
    end
  end

  it "marks dynamic superclasses as unknown instead of asserting missing methods" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Dynamic.rb", <<-RUBY)
        class DynamicChild < Struct.new(:name)
          def local
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        child = index.class_info("DynamicChild").not_nil!
        child.dynamic_superclass.should be_true
        child.open?.should be_true
        index.method_status(child, "local").should eq true
        index.method_status(child, "unknown").should be_nil
      ensure
        index.close
      end
    end
  end

  it "reports duplicate component tags as an analysis limitation" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/DuplicateTags.rb", <<-RUBY)
        class FirstDuplicate
          @tag_name = "duplicate-widget"
        end

        class SecondDuplicate
          @tag_name = "duplicate-widget"
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        index.diagnostics.size.should eq 1
        index.diagnostics.first.rule.should eq Lint::ANALYSIS_RULE
        index.diagnostics.first.message.should contain("duplicate component tag")
      ensure
        index.close
      end
    end
  end

  it "maps escaped quotes and attributes to authored bytes" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Escaped.rb", <<-RUBY)
        class EscapedWidget
          @tag_name = "escaped-widget"

          def html
            %Q{<div title="café">{@name}</div>
        <div title="café">{@name}</div>}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        template.text.should contain("title=\"café\"")
        template.attributes.size.should eq 2
        template.attributes.each do |attribute|
          attribute.name.should eq "title"
          template.map.source.byte_slice(
            template.source_byte(attribute.value_start),
            template.source_byte(attribute.value_end) - template.source_byte(attribute.value_start)
          ).should eq "café"
        end
        template.expressions.size.should eq 2
        template.expressions.each do |expression|
          template.map.source.byte_slice(
            template.source_byte(expression.template_start + 1),
            expression.source.bytesize
          ).should eq "@name"
        end
      ensure
        index.close
      end
    end
  end

  it "keeps Ruby escapes inside template expressions for validation" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/EscapedExpression.rb", <<-'RUBY')
        class EscapedExpression
          @tag_name = "escaped-expression"

          def html
            %Q{<button onclick="{handler("quote: \"x\"")}">Read escaped quotes</button>}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        template.expressions.first.source.should eq %q(handler("quote: \"x\""))
        index.diagnostics.should be_empty
      ensure
        index.close
      end
    end
  end

  it "maps repeated identical expressions to distinct authored locations" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Repeated.rb", <<-RUBY)
        class Repeated
          @tag_name = "repeated-widget"

          def html
            %Q{<p>{@value}</p>
        <p>{@value}</p>}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        template.expressions.size.should eq 2
        first_expression, second_expression = template.expressions
        template.map.source.byte_slice(
          template.source_byte(first_expression.template_start),
          first_expression.template_end - first_expression.template_start
        ).should eq "{@value}"
        template.map.source.byte_slice(
          template.source_byte(second_expression.template_start),
          second_expression.template_end - second_expression.template_start
        ).should eq "{@value}"
        template.source_range(first_expression.template_start, first_expression.template_end).start_line
          .should_not eq template.source_range(second_expression.template_start, second_expression.template_end).start_line
      ensure
        index.close
      end
    end
  end

  it "maps Unicode and CRLF template locations with character columns" do
    LintProjectIndexSpecSupport.with_project do |root|
      source = "class UnicodeWidget\r\n" \
               "  @tag_name = \"unicode-widget\"\r\n" \
               "\r\n" \
               "  def html\r\n" \
               "    %Q{<p>é{@name}</p>\r\n" \
               "<p>{@name}</p>}\r\n" \
               "  end\r\n" \
               "end\r\n"
      LintProjectIndexSpecSupport.write(root, "lib/Unicode.rb", source)

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        first_expression, second_expression = template.expressions
        first_range = template.source_range(first_expression.template_start, first_expression.template_end)
        second_range = template.source_range(second_expression.template_start, second_expression.template_end)

        first_range.start_line.should eq 5
        first_range.start_column.should eq 12
        second_range.start_line.should eq 6
        second_range.start_column.should eq 4
        template.map.source.byte_slice(
          template.source_byte(first_expression.template_start + 1),
          first_expression.source.bytesize
        ).should eq "@name"
      ensure
        index.close
      end
    end
  end

  it "maps heredoc templates without treating the terminator as markup" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Heredoc.rb", <<-RUBY)
        class HeredocWidget
          @tag_name = "heredoc-widget"

          def html
            <<~HTML
              <p>{@name}</p>
            HTML
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        template.text.should contain("<p>{@name}</p>")
        template.text.should_not contain("HTML")
        expression = template.expressions.first
        template.map.source.byte_slice(
          template.source_byte(expression.template_start),
          expression.template_end - expression.template_start
        ).should eq "{@name}"
      ensure
        index.close
      end
    end
  end

  it "reports the enclosing row scope for nested each blocks" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Rows.rb", <<-RUBY)
        class RowsWidget
          @tag_name = "rows-widget"

          def html
            %Q{
              <ul>
                {each @items as item, index}
                  <li>{item.name}</li>
                  {each item.tags as tag}
                    <span>{tag}</span>
                  {end}
                {end}
              </ul>
            }
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        template = index.target_templates.first
        tag_expression = template.expressions.find { |expression| expression.source == "tag" }.not_nil!
        template.scope_at(template.source_byte(tag_expression.template_start))
          .should eq ["item", "index", "tag"]
        index.diagnostics.should be_empty
      ensure
        index.close
      end
    end
  end

  it "reports unsupported with directives as analysis limitations" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/With.rb", <<-RUBY)
        class WithWidget
          @tag_name = "with-widget"

          def html
            %Q{{with @item}<p>ok</p>{end}}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        index.diagnostics.size.should eq 1
        index.diagnostics.first.rule.should eq Lint::ANALYSIS_RULE
        index.diagnostics.first.message.should contain("{with} directive is not supported")
      ensure
        index.close
      end
    end
  end

  it "reports malformed template source as a blocking analysis limitation" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Malformed.rb", <<-RUBY)
        class MalformedWidget
          @tag_name = "malformed-widget"

          def html
            "<p>{@name</p>"
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        index.diagnostics.size.should eq 1
        diagnosis = index.diagnostics.first
        diagnosis.rule.should eq Lint::ANALYSIS_RULE
        diagnosis.message.should contain("unclosed template placeholder")
      ensure
        index.close
      end
    end
  end

  it "keeps independent files available when one file has a syntax error" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Broken.rb", "class Broken\n  def html\n")
      LintProjectIndexSpecSupport.write(root, "lib/Good.rb", <<-RUBY)
        class Good
          def html
            %Q{<p>ok</p>}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root)
      begin
        index.units.size.should eq 2
        index.diagnostics.size.should eq 1
        index.diagnostics.first.rule.should eq Lint::SYNTAX_RULE
        index.class_info("Good").not_nil!.qualified_name.should eq "Good"
      ensure
        index.close
      end
    end
  end

  it "does not emit diagnostics for required support files excluded by configuration" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/support.rb", <<-RUBY)
        class SupportOne
          @tag_name = "support-widget"
        end

        class SupportTwo
          @tag_name = "support-widget"
        end
        RUBY
      LintProjectIndexSpecSupport.write(root, "lib/Target.rb", <<-RUBY)
        require_relative "support"

        class TargetWidget
          @tag_name = "target-widget"
          def html
            %Q{<p>ok</p>}
          end
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root, ["lib/Target.rb"])
      begin
        index.units.size.should eq 2
        index.unit("lib/support.rb").not_nil!.target?.should be_false
        index.diagnostics.should be_empty
      ensure
        index.close
      end
    end
  end

  it "parses each file once and reuses the injected parser" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/One.rb", <<-RUBY)
        require_relative "Two"

        class One
          def html
            %Q{<p>one</p>}
          end
        end
        RUBY
      LintProjectIndexSpecSupport.write(root, "lib/Two.rb", <<-RUBY)
        class Two
        end
        RUBY

      parser = TreeSitter::RubyParser.new
      count = 0
      parser.on_parse = ->(_source : String) { count += 1; nil }
      config = LintProjectIndexSpecSupport.config(root)
      files = Lint::FileDiscovery.discover(config.project_root, config)
      index = Lint::ProjectIndex.build(files, config, parser)
      begin
        index.parse_count.should eq 2
        count.should eq 2
        index.units.size.should eq 2
      ensure
        index.close
      end
    end
  end

  it "does not follow requires outside the selected project" do
    LintProjectIndexSpecSupport.with_project do |root|
      parent = File.dirname(root)
      outside = File.join(parent, "outside_#{Random.new.hex(8)}.rb")
      File.write(outside, "class Outside\nend\n")
      begin
        LintProjectIndexSpecSupport.write(root, "lib/Target.rb", <<-RUBY)
          require_relative "../../#{File.basename(outside, ".rb")}"

          class Target
          end
          RUBY

        index, _config = LintProjectIndexSpecSupport.build(root, ["lib/Target.rb"])

        begin
          index.units.size.should eq 1
          edge = index.unit("lib/Target.rb").not_nil!.requires.first
          edge.resolved_path.should be_nil
          edge.problem.should eq "local require not found"
        ensure
          index.close
        end
      ensure
        File.delete(outside) if File.exists?(outside)
      end
    end
  end

  it "records dynamic requires without resolving them" do
    LintProjectIndexSpecSupport.with_project do |root|
      LintProjectIndexSpecSupport.write(root, "lib/Target.rb", <<-RUBY)
        require File.join("lib", "support")
        require_relative "support_#{'#'}{index}"

        class Target
        end
        RUBY

      index, _config = LintProjectIndexSpecSupport.build(root, ["lib/Target.rb"])
      begin
        index.requires.size.should eq 2
        index.requires.each do |edge|
          edge.resolved_path.should be_nil
          edge.problem.should eq "dynamic require is not supported"
        end
      ensure
        index.close
      end
    end
  end
end
