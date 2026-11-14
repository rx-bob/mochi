require "spec"
require "../../src/ruby/component_event_method_generator"

describe ComponentEventMethodGenerator do
  it "injects an emit bridge for declared child events" do
    events = [
      ComponentEventDescriptor.new("select", [
        EventPayloadDescriptor.new("id", "integer"),
        EventPayloadDescriptor.new("label", "string"),
      ]),
    ]
    source = <<-RUBY
class EventRow
  def choose
    emit :select, id: 1, label: "One"
  end
end
RUBY

    result = ComponentEventMethodGenerator.inject_methods_into_class(source, "EventRow", events)
    result.should contain("def emit(__mochi_event, __mochi_payload = {})")
    result.should contain("Mochi.emit_child(__mochi_event.to_s, __mochi_payload)")
    result.should contain("def choose")
  end

  it "does not inject into classes without declared child events" do
    source = "class Plain\nend\n"
    ComponentEventMethodGenerator.inject_methods_into_class(
      source,
      "Plain",
      [] of ComponentEventDescriptor
    ).should eq(source)
  end
end
