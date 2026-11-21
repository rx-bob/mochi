class StationEditor
  @tag_name = "station-editor"

  @draft
  @open
  @locked
  @history
  @refreshes

  def initialize
    @draft = "Harbor"
    @open = false
    @locked = false
    @history = []
    @refreshes = 0
  end

  def record_name(draft, event)
    @history = @history + ["#{event["type"]}=#{draft}"]
  end

  def record_open(event)
    @history = @history + ["#{event["type"]}=#{@open}"]
  end

  def refresh_status
    @refreshes += 1
  end

  def toggle_lock
    @locked = !@locked
  end

  def html
    %Q{
      <div class="editor">
        <label for="station-name">Station name</label>
        <input id="station-name" type="text" data-field="name" oninput="{record_name(@draft, $event)}" bind:value="@draft" disabled="{@locked}">
        <div class="flag">
          <input id="station-open" type="checkbox" data-field="open" bind:checked="{@open}" onchange="{record_open($event)}" disabled="{@locked}">
          <label for="station-open">Open to public</label>
        </div>
        <div class="actions">
          <button class="action" data-action="refresh" onclick="{refresh_status}">Refresh status</button>
          <button class="action" data-action="lock" onclick="{toggle_lock}">Toggle editing</button>
        </div>
        <span data-view="status">Refreshes: {@refreshes}</span>
        <span data-view="history">{@history.join(" | ")}</span>
      </div>
    }
  end

  def css
    %Q{
      .editor {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
        background-color: #eff4f2;
        color: #162d27;
        line-height: 24px;
      }
      .flag {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .actions {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .action {
        padding: 8px;
        color: #ffffff;
        background-color: #26634f;
      }
    }
  end
end
