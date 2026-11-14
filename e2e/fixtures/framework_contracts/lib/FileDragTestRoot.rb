class FileDragTestRoot
  @tag_name = "file-drag-test-root"
  @received

  def initialize
    @received = "none"
  end

  def start_drag(_event)
    MochiDrag.set_data({ "active" => false, "count" => 3 })
  end

  def accept_drop(_event)
    MochiDrag.accept("application/vnd.mochi.value+json", "move")
  end

  def receive_drop(event)
    value = event["drag_value"]
    @received = "#{value["active"]}:#{value["count"]}:#{event["drag_effect"]}" if value
  end

  def html
    %Q{
      <button class="drag-source" draggable="true" ondragstart="{start_drag($event)}">Drag me</button>
      <section class="drag-target" ondragover="{accept_drop($event)}" ondrop="{receive_drop($event)}">
        <output class="drag-state">{@received}</output>
      </section>
    }
  end
end
