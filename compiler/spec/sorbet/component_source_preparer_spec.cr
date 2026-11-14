require "./spec_helper"
require "../../src/sorbet/component_source_preparer"

describe ComponentTypecheckSource do
  it "typechecks required/defaulted Boolean props and declared events with component-only shims" do
    source = <<-'RUBY'
# typed: true
class Editor
  @tag_name = "test-editor"
  prop :required, Boolean, required: true
  prop :disabled, Boolean, default: false
  prop :visible, Boolean, default: true
  event :save, valid: Boolean, value: String
  def save
    emit("save", {"valid" => true, "value" => "current"})
  end
end
RUBY
    prepared = ComponentTypecheckSource.prepare(source, "editor.rb")
    prepared.lines.size.should eq(source.lines.size)
    prepared.should contain("prop :required, T::Boolean, required: true")
    prepared.should contain("event :save, valid: T::Boolean, value: String")
    SorbetSpecHelper.with_session do |session|
      result = session.typecheck_files({"editor.rb" => prepared})
      result.errors.should be_empty, result.errors.map(&.message).join("\n")
    end
  end

  it "keeps unrelated constants, signed method errors, and helper DSL calls visible" do
    source = <<-'RUBY'
# typed: true
class Editor
  extend T::Sig
  @tag_name = "test-editor"
  prop :disabled, Boolean, default: false
  def unrelated
    Boolean
  end
  sig { returns(Integer) }
  def count
    "wrong"
  end
end
class Helper
  prop :other, String
end
RUBY
    SorbetSpecHelper.with_session do |session|
      result = session.typecheck_files({"invalid.rb" => ComponentTypecheckSource.prepare(source, "invalid.rb")})
      messages = result.errors.map(&.message).join("\n")
      messages.should contain("Unable to resolve constant `Boolean`")
      messages.should contain("Integer")
      messages.should contain("String")
      messages.should contain("prop")
      result.errors.any? { |error| error.line == 6 }.should be_true
    end
  end

  it "uses runtime declaration validation for invalid literal defaults and field types" do
    expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, "does not match boolean") do
      ComponentTypecheckSource.prepare(%(class Editor\n @tag_name = "test-editor"\n prop :enabled, Boolean, default: "false"\nend), "editor.rb")
    end
    expect_raises(TreeSitter::PropertyExtractor::EventDeclarationError, "unsupported type") do
      ComponentTypecheckSource.prepare(%(class Editor\n @tag_name = "test-editor"\n event :save, valid: Unknown\nend), "editor.rb")
    end
  end

  it "maps Sorbet columns back through multiple metadata rewrites and Unicode" do
    source = "# typed: true\nclass Editor; @tag_name = 'test-editor'; prop :flag, Boolean, default: MISSING; event :save, valid: Boolean; def bad; '😀'; UNKNOWN; end; end"
    prepared = ComponentTypecheckSource.prepare_with_map(source, "mapped.rb")
    SorbetSpecHelper.with_session do |session|
      result = session.typecheck_files({"mapped.rb" => prepared.code})
      ["MISSING", "UNKNOWN"].each do |name|
        error = result.errors.find! { |diagnostic| diagnostic.message.includes?("`#{name}`") }
        prefix = source.lines[1].split(name).first
        expected = prefix.bytesize
        prepared.authored_column(error.line, error.column).should eq(expected)
      end
    end
  end

  it "does not rewrite strings, defaults, method bodies, or non-component classes" do
    source = <<-'RUBY'
class Editor
  @tag_name = "test-editor"
  prop :enabled, Boolean, default: MISSING_DEFAULT
  LABEL = "Boolean"
  def html
    %q{<p>Boolean</p>}
  end
  def use
    Other.prop(:flag, Boolean)
  end
end
class Helper
  prop :flag, Boolean
end
RUBY
    prepared = ComponentTypecheckSource.prepare(source, "editor.rb")
    prepared.should contain("default: MISSING_DEFAULT")
    prepared.should contain(%(LABEL = "Boolean"))
    prepared.should contain("Other.prop(:flag, Boolean)")
    prepared.should contain("class Helper\n  prop :flag, Boolean\nend")
  end
end
