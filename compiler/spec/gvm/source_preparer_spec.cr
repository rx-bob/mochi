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
