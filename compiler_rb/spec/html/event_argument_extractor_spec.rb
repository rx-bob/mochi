# typed: false
require_relative "../test_helper"
require_relative "../../src/html/event_argument_extractor"

class EventArgumentExtractorTest < Minitest::Test
  def test_extracts_single_argument
    html = %Q(<button onclick="{delete_item(item.id)}">Delete</button>)
    result = EventArgumentExtractor.process(html)

    assert_includes result, %Q(onclick="{delete_item}")
    assert_includes result, %Q(data-mochi-arg-0="{item.id}")
  end

  def test_extracts_multiple_arguments
    html = %Q(<input onchange="{update_val(event, 5)}">)
    result = EventArgumentExtractor.process(html)

    assert_includes result, %Q(onchange="{update_val}")
    assert_includes result, %Q(data-mochi-arg-0="{event}")
    assert_includes result, %Q(data-mochi-arg-1="{5}")
  end

  def test_ignores_no_arguments
    html = %Q(<button onclick="{save}">Save</button>)
    result = EventArgumentExtractor.process(html)

    assert_equal html, result
  end

  def test_handles_empty_parentheses
    html = %Q(<button onclick="{save()}">Save</button>)
    result = EventArgumentExtractor.process(html)

    assert_equal %Q(<button onclick="{save}">Save</button>), result
  end

  def test_handles_magical_variables
    html = %Q(<div onclick="{handle_click($event, $element, item.id)}"></div>)
    result = EventArgumentExtractor.process(html)

    assert_includes result, %Q(onclick="{handle_click}")
    assert_includes result, %Q(data-mochi-arg-0="$event")
    assert_includes result, %Q(data-mochi-arg-1="$element")
    assert_includes result, %Q(data-mochi-arg-2="{item.id}")
  end
end
