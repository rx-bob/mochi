class DragSource
  @tag_name = "drag-source"
  @payload

  def initialize
    @payload = {
      "active" => false,
      "empty" => nil,
      "wide" => 9223372036854775807,
      "labels" => ["ruby", "mochi"]
    }
  end

  def start_drag(_event)
    MochiDrag.set_data(@payload)
  end

  def start_text_drag(_event)
    MochiDrag.set_text("external text stays text")
  end

  def html
    %Q{
      <section>
        <button class="typed-source" draggable="true" ondragstart="{start_drag($event)}">Typed value</button>
        <button class="text-source" draggable="true" ondragstart="{start_text_drag($event)}">Text value</button>
      </section>
    }
  end
end
