class FieldEditor
  @tag_name = "field-editor"
  prop :field_id, String, required: true
  prop :label, String, required: true
  prop :initial_value, String, required: true
  event :edit, value: String
  @draft
  @mount_count

  def initialize
    @draft = ""
    @mount_count = 0
  end

  def mounted
    @draft = @initial_value
    @mount_count += 1
    Mochi.route_subscribe
  end

  def on_route(payload)
    @path = payload["path"]
  end

  def edit(event)
    @draft = event["value"]
    emit("edit", {"value" => @draft})
  end

  def html
    %Q{
      <label class="editor" data-id="{@field_id}">
        <span class="label">{@label}</span>
        <input class="draft" value="{@draft}" oninput="{edit($event)}">
      </label>
      <span class="mount-count">{@mount_count}</span>
    }
  end
end
