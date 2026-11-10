require "json"
require "spec"
require "../../src/html/event_argument_extractor"

private def event_arguments(html : String, event : String) : Array(JSON::Any)
  match = html.match(/data-mochi-args-#{event}="(.*?)"/)
  match.should_not be_nil
  raw = match.not_nil![1]
    .gsub("&quot;", "\"")
    .gsub("&lt;", "<")
    .gsub("&gt;", ">")
    .gsub("&amp;", "&")
  JSON.parse(raw).as_a
end

describe EventArgumentExtractor do
  it "extracts a single expression argument" do
    html = %Q(<button onclick="{delete_item(item.id)}">Delete</button>)
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(onclick="{delete_item}"))

    args = event_arguments(result, "click")
    args.size.should eq(1)
    args[0]["kind"].as_s.should eq("expr")
    args[0]["value"].as_s.should eq("item.id")
  end

  it "classifies strings, integers, booleans, nil, and event arguments" do
    html = %Q(<input onchange="{update_val($event, 5, 'a,b', true, nil)}">)
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(onchange="{update_val}"))

    args = event_arguments(result, "change")
    args.map { |arg| arg["kind"].as_s }.should eq(["event", "literal", "literal", "literal", "literal"])
    args[1]["literal_type"].as_s.should eq("number")
    args[1]["value"].as_s.should eq("5")
    args[2]["literal_type"].as_s.should eq("string")
    args[2]["value"].as_s.should eq("a,b")
    args[3]["literal_type"].as_s.should eq("boolean")
    args[3]["value"].as_s.should eq("true")
    args[4]["literal_type"].as_s.should eq("null")
  end

  it "ignores no arguments" do
    html = %Q(<button onclick="{save}">Save</button>)
    result = EventArgumentExtractor.process(html)

    result.should eq html
  end

  it "handles empty parentheses" do
    html = %Q(<button onclick="{save()}">Save</button>)
    result = EventArgumentExtractor.process(html)

    result.should eq %Q(<button onclick="{save}">Save</button>)
  end

  it "handles magical variables $event and $element" do
    html = %Q(<div onclick="{handle_click($event, $element, item.id)}"></div>)
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(onclick="{handle_click}"))

    args = event_arguments(result, "click")
    args[0]["kind"].as_s.should eq("event")
    args[1]["kind"].as_s.should eq("element")
    args[2]["kind"].as_s.should eq("expr")
    args[2]["value"].as_s.should eq("item.id")
  end

  it "keeps nested calls and quoted commas inside one argument" do
    html = %Q(<button onclick="{select_row('tr_9f2a', format(1, 2), 'a,b')}"></button>)
    result = EventArgumentExtractor.process(html)

    args = event_arguments(result, "click")
    args.size.should eq(3)
    args[0]["value"].as_s.should eq("tr_9f2a")
    args[1]["kind"].as_s.should eq("expr")
    args[1]["value"].as_s.should eq("format(1, 2)")
    args[2]["value"].as_s.should eq("a,b")
  end
end
