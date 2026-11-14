require 'json'

class StorageRoot
  @tag_name = "storage-root"

  DEFAULT_JSON = '{"theme":"light","density":"comfortable"}'
  DARK_JSON = '{"theme":"dark","density":"compact"}'
  STORAGE_KEY = "mochi_e4s2_preferences"

  def initialize
    @store = MochiStore.build(STORAGE_KEY, DEFAULT_JSON)
    raw = MochiStore.value(@store)
    if valid_preferences_text?(raw)
      @preferences = JSON.parse(raw)
      @status = "loaded"
    else
      @preferences = JSON.parse(DEFAULT_JSON)
      @status = "repaired"
      MochiStore.write(@store, DEFAULT_JSON)
    end
    @updates = 0
    Mochi.storage_subscribe(STORAGE_KEY, "on_preferences")
  end

  def valid_preferences_text?(raw)
    return false unless raw == DEFAULT_JSON || raw == DARK_JSON
    value = JSON.parse(raw)
    value.is_a?(Hash) && value.length == 2 &&
      value["theme"].is_a?(String) && (value["theme"] == "light" || value["theme"] == "dark") &&
      value["density"].is_a?(String) && (value["density"] == "comfortable" || value["density"] == "compact")
  end

  def apply_preferences(raw)
    if valid_preferences_text?(raw)
      @preferences = JSON.parse(raw)
      @status = "loaded"
    else
      @preferences = JSON.parse(DEFAULT_JSON)
      @status = "repaired"
      MochiStore.write(@store, DEFAULT_JSON)
    end
  end

  def on_preferences(payload)
    raw = MochiStore.accept(@store, payload)
    @updates = @updates + 1
    if payload["ok"] == false
      apply_preferences(raw)
      @status = MochiStore.error(@store)
    else
      apply_preferences(raw)
    end
  end

  def save
    next_value = @preferences["theme"] == "light" ? JSON.parse(DARK_JSON) : JSON.parse(DEFAULT_JSON)
    raw = JSON.generate(next_value)
    if MochiStore.write(@store, raw)
      @status = "saving"
    else
      @status = "saved"
    end
  end

  def save_current
    if !MochiStore.write(@store, JSON.generate(@preferences))
      error = MochiStore.error(@store)
      @status = error == "" ? "unchanged" : error
    end
  end

  def html
    %Q{
      <main>
        <output class="theme">{@preferences["theme"]}</output>
        <output class="density">{@preferences["density"]}</output>
        <output class="status">{@status}</output>
        <output class="updates">{@updates}</output>
        <button class="save" onclick="{save}">Save draft</button>
        <button class="save-current" onclick="{save_current}">Save current draft</button>
      </main>
    }
  end
end
