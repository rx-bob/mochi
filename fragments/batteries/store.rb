class MochiStore
  # A small optional wrapper for one string-valued storage key. Components
  # subscribe directly with `Mochi.storage_subscribe(key, callback)` so the
  # host can bind the callback to the mounted component instance.
  def self.build(key, default_value)
    default_text = default_value.to_s
    {
      "key" => key.to_s,
      "default" => default_text,
      "value" => default_text,
      "error" => ""
    }
  end

  def self.value(store)
    stored = Mochi.storage_get(store["key"], nil)
    value = store["default"]
    if stored != nil && stored != ""
      value = stored
    end
    store["value"] = value
    value
  end

  def self.accept(store, payload)
    if payload["ok"] == false
      error = payload["error"]
      if error == nil || error == ""
        error = "unavailable"
      end
      store["error"] = error
      return store["value"]
    end

    value = payload["value"]
    if value == nil || value == ""
      value = store["default"]
    end
    value = value.to_s
    store["error"] = ""
    store["value"] = value
    value
  end

  def self.write(store, value)
    next_value = value.to_s
    current = Mochi.storage_get(store["key"], nil)
    if current == next_value
      store["value"] = next_value
      store["error"] = ""
      return false
    end
    Mochi.storage_set(store["key"], next_value)
    store["value"] = next_value
    store["error"] = ""
    true
  end

  def self.clear(store)
    Mochi.storage_remove(store["key"])
    store["value"] = store["default"]
    store["error"] = ""
    store["default"]
  end

  def self.error(store)
    store["error"]
  end
end
