class FieldEditor
  @tag_name = "field-editor"
  prop :field_id, String, required: true
  prop :label, String, required: true
  prop :initial_value, String, required: true
  event :edit, value: String
  @draft
  @mount_count
  @validation

  def initialize
    @draft = ""
    @mount_count = 0
    @validation = "Unedited"
  end

  def mounted
    @draft = @initial_value
    @mount_count += 1
    Mochi.route_subscribe
  end

  def on_route(payload)
    @path = payload["path"]
  end

  def edit
    @validation = @draft.empty? ? "Required" : "Valid: #{@draft}"
    emit("edit", {"value" => @draft})
  end

  def html
    %Q{
      <label class="editor" data-id="{@field_id}">
        <span class="label">{@label}</span>
        <input class="draft" bind:value="{@draft}" oninput="{edit}">
      </label>
      <span class="mount-count">{@mount_count}</span>
      <span class="draft-validation">{@validation}</span>
    }
  end
end
