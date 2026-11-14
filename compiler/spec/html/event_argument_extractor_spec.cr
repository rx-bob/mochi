require "json"
require "html"
require "spec"
require "../../src/html/event_argument_extractor"

private def event_arguments(html : String, event : String) : Array(JSON::Any)
  match = html.match(/data-mochi-args-#{event}="(.*?)"/)
  match.should_not be_nil
  raw = HTML.unescape(match.not_nil![1])
  JSON.parse(raw).as_a
end

describe EventArgumentExtractor do
  it "leaves escapes and interpolation to Ruby evaluation" do
    [%q("#{@field["label"]}"), %q("#@label"), %q("#$global"), %q('a\nb'), %q("a\"b"), %q("a" + "b")].each do |source|
      argument = EventArgumentDescriptor.parse(source)
      argument.kind.should eq("expr")
      argument.value.should eq(source)
    end
    EventArgumentDescriptor.parse(%q('#{literal}')).value.should eq("#" + "{literal}")
  end

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

  it "extracts component event bindings and keeps their payload arguments" do
    html = %Q(<event-row on:select="{row_selected($event, 7)}"></event-row>)
    _result, calls = EventArgumentExtractor.rewrite(html) do |call|
      %(on:#{call.event}="{#{call.method_name}}")
    end

    calls.size.should eq 1
    calls[0].component?.should be_true
    calls[0].event.should eq "select"

    processed = EventArgumentExtractor.process(html)
    processed.should contain(%Q(on:select="{row_selected}"))
    args = event_arguments(processed, "select")
    args.map { |arg| arg["kind"].as_s }.should eq(["event", "literal"])
  end

  it "rejects empty, unbraced, and mixed-literal child event bindings" do
    [
      %Q(<child-row on:action=""></child-row>),
      %Q(<child-row on:action="handle"></child-row>),
      %Q(<child-row on:action="prefix {handle} suffix"></child-row>),
    ].each do |html|
      error = expect_raises(TemplateExpressionError) do
        EventArgumentExtractor.process(html)
      end
      error.message.to_s.should contain("invalid child event binding")
      error.message.to_s.should contain("on:action")
      error.message.to_s.should contain("on:action=\"{handle($event)}\"")
    end
  end

  it "keeps multiple valid child event bindings" do
    html = %Q(<child-row on:action="{save($event)}" on:change="{changed}"></child-row>)
    _result, calls = EventArgumentExtractor.rewrite(html) { |call| call.method_name }

    calls.map(&.event).should eq(["action", "change"])
  end

  it "parses synchronous event modifiers into a loader-readable attribute" do
    html = %Q(<a href="#save" onclick.prevent.stop.self="{save(item.id)}">Save</a>)
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(onclick.prevent.stop.self="{save}"))
    result.should contain(%Q(data-mochi-modifiers-click="prevent,stop,self"))
    args = event_arguments(result, "click")
    args[0]["kind"].as_s.should eq("expr")
    args[0]["value"].as_s.should eq("item.id")
  end

  it "keeps modifiers on component event bindings" do
    _result, calls = EventArgumentExtractor.rewrite(
      %Q(<event-row on:select.self="{row_selected}"></event-row>)
    ) do |call|
      %(on:#{call.event}="#{call.method_name}")
    end

    calls.size.should eq 1
    calls[0].event.should eq "select"
    calls[0].component?.should be_true
    calls[0].modifiers.should eq(["self"])
  end

  it "rejects unknown or repeated event modifiers" do
    expect_raises(TemplateExpressionError, /unknown event modifier/) do
      EventArgumentExtractor.process(%Q(<button onclick.fire="{save}">Save</button>))
    end
    expect_raises(TemplateExpressionError, /duplicate event modifier/) do
      EventArgumentExtractor.process(%Q(<button onclick.stop.stop="{save}">Save</button>))
    end
  end

  it "finds event attributes after multibyte text" do
    html = %Q[<p>café</p><button onclick="{delete_item(item.id, "}")}">Delete</button>]
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(onclick="{delete_item}"))
    args = event_arguments(result, "click")
    args.size.should eq(2)
    args[0]["value"].as_s.should eq("item.id")
    args[1]["value"].as_s.should eq("}")
  end

  it "uses the caller's shared parser for event source locations" do
    html = %Q[\n<button onclick="{save(@count)}">Save</button>]
    locator = TemplateSourceLocator.new(html, "lib/actions.rb")
    parser = TemplateExpressionParser.new(locator)
    _result, calls = EventArgumentExtractor.rewrite(html, locator, parser) do |call|
      call.method_name
    end

    calls.first.span.not_nil!.file.should eq("lib/actions.rb")
    calls.first.span.not_nil!.line.should eq(2)
  end

  it "does not read the on substring inside ordinary data attributes as an event" do
    html = %Q(<div data-component-id="{item.id}"></div><button onclick="{save}">Save</button>)
    result = EventArgumentExtractor.process(html)

    result.should contain(%Q(data-component-id="{item.id}"))
    result.should contain(%Q(onclick="{save}"))
  end
end
