require "spec"
require "../../src/gvm/source_preparer"

describe GvmSourcePreparer do
  it "removes class-level instance variables but keeps method state" do
    source = <<-RUBY
class MyCounter
  @tag_name = "my-counter"
  @count

  def initialize
    @count = 0
  end

  def increment
    @count += 1
  end
end
RUBY

    result = GvmSourcePreparer.strip_class_ivars(source)
    result.should_not contain("@tag_name")
    result.should contain("def initialize")
    result.should contain("    @count = 0")
    result.should contain("    @count += 1")
  end

  it "removes declared prop metadata but keeps generated prop installation" do
    source = <<-RUBY
class Badge
  @tag_name = "badge"
  prop :label, String, default: "unset"
  prop :count, Integer

  def __mochi_apply_props(__mochi_props, __mochi_initial)
    @label = __mochi_props["label"]
  end
end
RUBY

    result = GvmSourcePreparer.strip_class_ivars(source)
    result.should_not contain("prop :label")
    result.should_not contain("prop :count")
    result.should contain("def __mochi_apply_props")
    result.should contain("    @label = __mochi_props[\"label\"]")
  end

  it "removes child event declarations but keeps the generated emitter" do
    source = <<-RUBY
class EventRow
  @tag_name = "event-row"
  event :select, id: Integer, label: String

  def emit(__mochi_event, __mochi_payload = {})
    Mochi.emit_child(__mochi_event.to_s, __mochi_payload)
  end
end
RUBY

    result = GvmSourcePreparer.strip_class_ivars(source)
    result.should_not contain("event :select")
    result.should contain("def emit")
    result.should contain("Mochi.emit_child")
  end

  it "leaves method-level instance variables in a class without metadata" do
    source = <<-RUBY
class Plain
  def initialize
    @value = 1
  end
end
RUBY

    GvmSourcePreparer.strip_class_ivars(source).should eq(source)
  end

  it "strips class metadata from every class in a multi-class source" do
    source = <<-RUBY
HELPER = 1

class Screen
  @tag_name = "x-screen"
  @count
  def initialize
    @count = 0
  end
end

class Row
  @tag_name = "x-row"
  @label
  def initialize
    @label = "row"
  end
end
RUBY

    result = GvmSourcePreparer.strip_class_ivars(source)
    result.should_not contain("@tag_name")
    result.should_not contain("  @count\n")
    result.should_not contain("  @label\n")
    result.should contain("@count = 0")
    result.should contain("@label = \"row\"")
    result.should contain("HELPER = 1")
  end
end

describe "helper source preparation" do
  it "retains namespace, receiver, block locals, and original lines" do
    source = "module RecordData\n  BASE = 7\n  def self.build\n    [1, 2].map { |x| next BASE if x == 2; x }\n  end\nend\nclass Probe\n  @tag_name = 'probe'\n  def value\n    RecordData::BASE + RecordData.build[0]\n  end\nend\n"
    prepared = GvmSourcePreparer.strip_class_ivars(source)
    prepared.lines[0, 7].should eq(source.lines[0, 7])
    prepared.lines[8..].should eq(source.lines[8..])
    GvmSourcePreparer.validate_control_flow!(prepared, "lib/probe.rb")
  end

  it "rejects redo with the authored path and offset without matching strings" do
    GvmSourcePreparer.validate_control_flow!("def value; 'redo'; end", "lib/probe.rb")
    expect_raises(Exception, "lib/probe.rb:12: unsupported redo") do
      GvmSourcePreparer.validate_control_flow!("def value\n [1].each { redo }\nend", "lib/probe.rb", 11)
    end
  end
end
