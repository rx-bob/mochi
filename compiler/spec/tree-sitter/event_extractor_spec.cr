require "spec"
require "../../src/tree-sitter/property_extractor"

describe "TreeSitter::PropertyExtractor.extract_events" do
  it "reads event names, typed payload fields, and source lines" do
    source = <<-RUBY
class EventRow
  @tag_name = "event-row"
  event :select, id: Integer, label: String, active: Boolean, tags: Array, meta: Hash
  event :opened
end
RUBY

    events = TreeSitter::PropertyExtractor.extract_events(source, "event_row.rb")
    events.size.should eq 2
    events[0].name.should eq "select"
    events[0].line.should eq 3
    events[0].payload.map(&.name).should eq ["id", "label", "active", "tags", "meta"]
    events[0].payload.map(&.type).should eq ["integer", "string", "boolean", "array", "hash"]
    events[1].name.should eq "opened"
    events[1].payload.should be_empty
  end

  it "ignores nested classes and receiver-qualified calls" do
    source = <<-RUBY
class Outer
  @tag_name = "outer"
  event :chosen, id: Integer

  class Inner
    event :nested, id: String
  end

  Schema.event :not_a_component_event, id: String
end
RUBY

    events = TreeSitter::PropertyExtractor.extract_events(source)
    events.map(&.name).should eq ["chosen"]
  end

  it "rejects invalid names, duplicate fields, and unsupported types" do
    expect_raises(TreeSitter::PropertyExtractor::EventDeclarationError, /lower_snake_case/) do
      TreeSitter::PropertyExtractor.extract_events("class Badge\n  event :\"Bad-Name\"\nend", "badge.rb")
    end

    expect_raises(TreeSitter::PropertyExtractor::EventDeclarationError, /twice/) do
      TreeSitter::PropertyExtractor.extract_events(
        "class Badge\n  event :select, id: Integer, id: String\nend",
        "badge.rb"
      )
    end

    expect_raises(TreeSitter::PropertyExtractor::EventDeclarationError, /unsupported type Symbol/) do
      TreeSitter::PropertyExtractor.extract_events(
        "class Badge\n  event :select, id: Symbol\nend",
        "badge.rb"
      )
    end
  end
end
