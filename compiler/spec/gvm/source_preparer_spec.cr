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
end
