class StationEditor
  @tag_name = "station-editor"

  prop :station_id, String, required: true
  prop :station_name, String, required: true
  prop :public_access, Boolean, required: true

  event :saved, id: String, name: String, open: Boolean
  event :cancelled

  @name
  @open
  @key
  @pending
  @announcement
  @invalid

  def initialize
    @name = @station_name
    @open = @public_access
    @key = StationRecords.key(@station_id)
    @pending = nil
    @announcement = ""
    @invalid = false
    Mochi.storage_subscribe(@key, :saved)
  end

  def mounted
    Mochi.focus(:station_name)
  end

  def name_changed
    @invalid = false
    @announcement = ""
  end

  def save_disabled
    @name.strip == @station_name && @open == @public_access
  end

  def save
    return if @pending || save_disabled
    name = @name.strip
    if name.empty?
      @invalid = true
      @announcement = "Enter a station name."
      Mochi.focus(:station_name)
      return
    end
    @pending = Mochi.json_generate({"name" => name, "open" => @open})
    if Mochi.storage_get(@key) == @pending
      finish_save
    else
      Mochi.storage_set(@key, @pending)
    end
  end

  def saved(receipt)
    return unless @pending && receipt["source"] == "same_tab"
    if !receipt["ok"]
      @pending = nil
      @announcement = "Could not save station. Try again."
    elsif receipt["value"] == @pending
      finish_save
    end
  end

  def finish_save
    record = Mochi.json_parse(@pending)
    @pending = nil
    emit :saved, id: @station_id, name: record["name"], open: record["open"]
  end

  def cancel
    emit :cancelled
  end

  def html
    %Q{
      <div class="editor" data-view="editor">
        <span data-view="editor-heading">Edit station {@station_id}</span>
        <label data-view="name-label" for="station-name">Station name</label>
        <input data-view="name-field" id="station-name" ref="station_name" type="text" bind:value="@name" oninput="{name_changed}" aria-invalid="{@invalid}">
        <div class="flag">
          <input data-view="open-field" id="station-open" type="checkbox" tabindex="0" bind:checked="@open">
          <label data-view="open-label" for="station-open">Open to public</label>
        </div>
        <span class="message" data-view="editor-message" aria-live="polite" aria-atomic="true">{@announcement}</span>
        <div class="editor-actions">
          <button class="save {if save_disabled}unavailable{end}" data-action="save" tabindex="0" disabled="{save_disabled}" onclick="{save}">Save station</button>
          <button class="cancel" data-action="cancel" tabindex="0" onclick="{cancel}">Cancel</button>
        </div>
      </div>
    }
  end

  def css
    %Q{
      .editor {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 12px;
        background-color: #d3e8de;
        color: #162d27;
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 16px;
        line-height: 24px;
      }
      .flag {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .message {
        height: 24px;
        color: #882524;
      }
      .editor-actions {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .save {
        padding: 8px;
        color: #ffffff;
        background-color: #26634f;
      }
      .unavailable {
        color: #344940;
        background-color: #c1d4ca;
      }
      .cancel {
        padding: 8px;
        background-color: #ffffff;
      }
    }
  end
end
