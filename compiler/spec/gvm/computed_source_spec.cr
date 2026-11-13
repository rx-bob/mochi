require "spec"
require "../../src/gvm/computed_source"

describe ComputedSource do
  it "flattens explicit dependencies without moving method lines" do
    source = <<-RUBY
class Screen
  @records
  computed :rows, depends_on: [:@records]
  computed :label, depends_on: [:rows]
  def rows
    @records.map { |record| record + 1 }
  end
  def label
    rows.length.to_s
  end
end
RUBY
    prepared = ComputedSource.prepare(source, "screen.rb")
    prepared.should contain("__mochi_computed(:label, [:@records])")
    prepared.lines[4..].should eq(source.lines[4..])
    erased = ComputedSource.prepare(source, "screen.rb", erase: true)
    erased.lines[4..].should eq(source.lines[4..])
    erased.bytesize.should eq(source.bytesize)
  end

  {
    "unknown dependency @missing"  => "computed :rows, depends_on: [:@missing]\ndef rows; 1; end",
    "dependency cycle"             => "computed :rows, depends_on: [:rows]\ndef rows; rows; end",
    "unknown method rows"          => "computed :rows, depends_on: []",
    "must take no arguments"       => "computed :rows, depends_on: []\ndef rows(x); x; end",
    "undeclared dependency @other" => "computed :rows, depends_on: []\ndef rows; @other; end",
    "must not write state"         => "computed :rows, depends_on: [:@x, :@y]\ndef rows; @x, @y = [1, 2]; end",
    "must not emit effects"        => "computed :rows, depends_on: []\ndef rows; effect; end\ndef effect; Mochi.emit('x'); end",
    "dependencies must be literal" => "computed :rows, depends_on: deps\ndef rows; 1; end",
  }.each do |message, body|
    it "rejects #{message} with source context" do
      error = expect_raises(Exception) { ComputedSource.prepare("class Screen\n#{body}\nend", "screen.rb", 10) }
      error.message.not_nil!.should contain("screen.rb:11") if message.starts_with?(/^(unknown|dependency|dependencies)/)
      error.message.not_nil!.should contain(message)
    end
  end

  it "distinguishes locals and explicit receivers from component calls" do
    source = <<-RUBY
class Screen
  computed :rows, depends_on: []
  computed :label, depends_on: []
  def rows
    [1]
  end
  def label
    rows = [1]
    rows.map { |length| length.to_s }.length
  end
  def length
    @illegal = 1
  end
end
RUBY
    ComputedSource.prepare(source, "screen.rb").should contain("__mochi_computed(:label, [])")
  end

  it "keeps block locals scoped and checks calls before local assignments" do
    ["[1].each { |rows| rows.to_s }; rows", "rows; rows = 1"].each do |body|
      source = "class Screen\ncomputed :rows, depends_on: []\ncomputed :label, depends_on: []\ndef rows; [1]; end\ndef label; #{body}; end\nend"
      expect_raises(Exception, "undeclared dependency rows") { ComputedSource.prepare(source, "screen.rb") }
    end
  end

  it "checks dependencies and effects in helper defaults" do
    ["@other", "Mochi.emit('forbidden')"].each do |default|
      source = "class Screen\ncomputed :rows, depends_on: []\ndef rows; helper; end\ndef helper(value = #{default}); value; end\nend"
      message = default == "@other" ? "undeclared dependency @other" : "must not emit effects"
      expect_raises(Exception, message) { ComputedSource.prepare(source, "screen.rb") }
    end
  end
end
