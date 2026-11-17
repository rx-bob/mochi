class FieldEditor
  @tag_name = "field-editor"
  prop :field_id, String, required: true
  prop :label, String, required: true
  prop :initial_value, String, required: true
  prop :required, Boolean, required: true
  prop :disabled, Boolean, default: false
  event :edit, value: String
  event :save, value: String, valid: Boolean
  event :cancel, discarded: Boolean
  @draft
  @mount_count
  @validation
  @invalid

  def initialize
    @draft = ""
    @mount_count = 0
    @validation = "Unedited"
    @invalid = false
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
    @invalid = @required && @draft.empty?
    @validation = @invalid ? "Required" : "Valid: #{@draft}"
    emit("edit", {"value" => @draft})
  end

  def save
    emit("save", {"value" => @draft, "valid" => !(@required && @draft.empty?)})
  end

  def cancel
    emit("cancel", {"discarded" => @draft != @initial_value})
  end

  def html
    %Q{
      <form onsubmit.prevent="{save}">
      <label for="draft" class="editor" data-id="{@field_id}">
        <span class="label">{@label}</span>
        <input id="draft" class="draft" type="text" required="{@required}" disabled="{@disabled}" aria-invalid="{@invalid}" aria-describedby="validation" bind:value="{@draft}" oninput="{edit}">
      </label>
      <span class="mount-count">{@mount_count}</span>
      <span id="validation" class="draft-validation">{@validation}</span>
      {if @invalid}
        <p class="error" role="alert">Please enter {@label}</p>
      {end}
      <button tabindex="0" class="save" type="submit" disabled="{@disabled}">Save</button>
      <button tabindex="0" class="cancel" type="button" onclick="{cancel}">Cancel</button>
      </form>
      <output class="contract">{@required}:{@disabled}</output>
    }
  end
end
