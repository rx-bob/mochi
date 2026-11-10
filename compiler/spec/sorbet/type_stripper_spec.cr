require "spec"
require "../../src/sorbet/type_stripper"

describe SorbetTypeStripper do
  it "removes signatures and unwraps typed expressions" do
    source = <<-RUBY
extend T::Sig

sig { params(count: Integer).returns(String) }
def render(count)
  value = T.let(0, Integer)
  label = T.must(@label)
  items = T.cast([], T::Array[String])
  empty = T::Array[String].new
  "\#{value}:\#{label}:\#{items}:\#{empty}"
end
RUBY

    stripped = SorbetTypeStripper.strip(source)

    stripped.should_not contain("extend T::Sig")
    stripped.should_not contain("sig {")
    stripped.should_not contain("T.let")
    stripped.should_not contain("T.must")
    stripped.should_not contain("T.cast")
    stripped.should_not contain("T::Array")
    stripped.should contain("value = 0")
    stripped.should contain("label = @label")
    stripped.should contain("items = []")
    stripped.should contain("empty = Array.new")
  end

  it "removes magic comments, include T::Sig, and do/end signatures" do
    source = <<-RUBY
# typed: strict
include T::Sig

sig do
  params(count: Integer).returns(String)
end
def render(count)
  T.unsafe(count)
end
RUBY

    stripped = SorbetTypeStripper.strip(source)

    stripped.should_not contain("# typed:")
    stripped.should_not contain("include T::Sig")
    stripped.should_not contain("sig do")
    stripped.should contain("def render(count)")
    stripped.should contain("count")
  end

  it "replaces generic type constants with runtime constants" do
    source = <<-RUBY
def build
  @array = T::Array[String].new
  @hash = T::Hash[Symbol, Integer].new
  @flag = T::Boolean
end
RUBY

    stripped = SorbetTypeStripper.strip(source)

    stripped.should contain("@array = Array.new")
    stripped.should contain("@hash = Hash.new")
    stripped.should contain("@flag = TrueClass")
  end

  it "balances nested delimiters and keeps commas inside arguments" do
    source = <<-RUBY
sig { params(value: T.untyped).void }
def update
  @value = T.let(foo(bar, { count: 1 }), T::Hash[Symbol, Integer])
  @name = T.cast(users.fetch(0, nil), String)
  @other = T.must(T.let(7, Integer))
end
RUBY

    stripped = SorbetTypeStripper.strip(source)

    stripped.should contain("@value = foo(bar, { count: 1 })")
    stripped.should contain("@name = users.fetch(0, nil)")
    stripped.should contain("@other = 7")
    stripped.should_not contain("T.untyped")
  end

  it "removes type aliases" do
    source = <<-RUBY
T.type_alias { T::Array[String] }
T.type_alias = T::Hash[Symbol, Integer]
class Example
end
RUBY

    stripped = SorbetTypeStripper.strip(source)

    stripped.should_not contain("T.type_alias")
    stripped.should_not contain("T::Array")
    stripped.should_not contain("T::Hash")
    stripped.should contain("class Example")
  end

  it "does not rewrite strings or comments" do
    source = <<-RUBY
# T.must(value) and sig { void } stay in comments
def text
  "T.let(1, Integer) sig { void }"
end
RUBY

    SorbetTypeStripper.strip(source).should contain(%Q{"T.let(1, Integer) sig { void }"})
    SorbetTypeStripper.strip(source).should contain("# T.must(value) and sig { void } stay in comments")
  end
end
