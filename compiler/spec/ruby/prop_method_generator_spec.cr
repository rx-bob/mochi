require "spec"
require "../../src/ruby/prop_method_generator"

describe PropMethodGenerator do
  it "injects one install-and-default branch per declared prop" do
    props = [
      PropDescriptor.new("label", "string", default: true, default_code: %("unset")),
      PropDescriptor.new("count", "integer", default: true, default_code: "0"),
      PropDescriptor.new("rows", "array", default: true, default_code: "[]"),
      PropDescriptor.new("note", "string"),
    ]
    source = <<-RUBY
class Badge
  def initialize
    @ready = true
  end
end
RUBY

    result = PropMethodGenerator.inject_methods_into_class(source, "Badge", props)
    result.should contain("def __mochi_apply_props(__mochi_props, __mochi_initial)")
    result.should contain(%(if __mochi_props.key?("label")))
    result.should contain(%(@label = __mochi_props["label"]))
    result.should contain(%(@label = "unset"))
    result.should contain("@count = 0")
    result.should contain("@rows = []")
    result.should contain("@note = nil")
    result.should contain("def initialize")
  end

  it "does not inject into classes without declared props" do
    source = "class Plain\nend\n"
    PropMethodGenerator.inject_methods_into_class(source, "Plain", [] of PropDescriptor).should eq(source)
  end
end
