class DragTarget
  @tag_name = "drag-target"
  @received
  @external_text
  @effect
  @source_tag

  def initialize
    @received = nil
    @external_text = ""
    @effect = "none"
    @source_tag = ""
  end

  def allow_typed(event)
    MochiDrag.accept("application/vnd.mochi.value+json", "move")
  end

  def allow_text(event)
    MochiDrag.accept("text/plain", "copy")
  end

  def receive(event)
    @received = event["drag_value"] if event["drag_value"]
    @external_text = event["drag_text"] if event["drag_text"] != ""
    @effect = event["drag_effect"]
    source = event["drag_source"]
    @source_tag = source["tag"] if source
  end

  def typed_value
    @received ? "#{@received["active"]}:#{@received["empty"]}:#{@received["wide"]}:#{@received["labels"].join(",")}" : "none"
  end

  def html
    %Q{
      <section class="drop-zone" ondragover="{allow_typed($event)}" ondrop="{receive($event)}">
        <output class="typed">{typed_value}</output>
        <output class="text">{@external_text}</output>
        <output class="effect">{@effect}</output>
        <output class="source">{@source_tag}</output>
      </section>
      <section class="text-zone" ondragover="{allow_text($event)}" ondrop="{receive($event)}">
        <output class="text-result">{@external_text}</output>
      </section>
    }
  end
end
