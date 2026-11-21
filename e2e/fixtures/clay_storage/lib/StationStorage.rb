class StationStorage
  @tag_name = "station-storage"
  KEY = "station-label"
  LABEL = "Café\n\"West\""
  RAW = "Café\u0000\u0008\u001f"

  @store
  @boot
  @receipt
  @count
  @mirror

  def initialize
    @store = MochiStore.build(KEY, "Default")
    @boot = identify(Mochi.get_storage(KEY, "Default"))
    @receipt = "pending"
    @mirror = @boot
    @count = 0
    Mochi.storage_subscribe(KEY, :received)
  end

  def identify(value)
    return "absent" if value.nil?
    return "empty" if value == ""
    return "label" if value == LABEL
    return "raw" if value == RAW

    value
  end

  def received(payload)
    MochiStore.accept(@store, payload)
    @count += 1
    status = payload["ok"] ? "ok" : payload["error"]
    @receipt = "#{payload["source"]} #{status} #{identify(payload["value"])} #{identify(payload["previous"])} #{@count}"
    @mirror = identify(Mochi.storage_get(KEY, "Default"))
  end

  def save
    MochiStore.write(@store, LABEL)
  end

  def save_equal
    Mochi.set_storage(KEY, LABEL)
  end

  def save_empty
    Mochi.storage_set(KEY, "")
  end

  def remove
    Mochi.remove_storage(KEY)
  end

  def save_quota
    Mochi.storage_set(KEY, "q" * 5000)
  end

  def save_unavailable
    Mochi.storage_set(KEY, "unavailable probe")
  end

  def save_raw
    Mochi.storage_set(KEY, RAW)
  end

  def abort_write
    Mochi.storage_set(KEY, "tentative")
    1 / 0
  end

  def html
    %Q{
      <div class="panel">
        <span data-view="boot">{@boot}</span>
        <span data-view="receipt">{@receipt}</span>
        <span data-view="mirror">{@mirror}</span>
        <button data-action="save" onclick="{save}">Save label</button>
        <button data-action="equal" onclick="{save_equal}">Save equal label</button>
        <button data-action="empty" onclick="{save_empty}">Save empty label</button>
        <button data-action="remove" onclick="{remove}">Remove label</button>
        <button data-action="quota" onclick="{save_quota}">Try oversized label</button>
        <button data-action="unavailable" onclick="{save_unavailable}">Try alternate label</button>
        <button data-action="raw" onclick="{save_raw}">Save raw control characters</button>
        <button data-action="abort" onclick="{abort_write}">Abort write</button>
      </div>
    }
  end

  def css
    %Q{
      .panel {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
      }
    }
  end
end
