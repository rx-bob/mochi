module StationRecords
  def self.key(id)
    "station-record-#{id}"
  end

  def self.read(id, name, label)
    saved = Mochi.storage_get(key(id))
    record = Mochi.json_parse(saved) if saved
    if record.is_a?(Hash) && record["name"].is_a?(String) && (record["open"] == true || record["open"] == false)
      return {"id" => id, "name" => record["name"], "label" => label, "open" => record["open"]}
    end
    {"id" => id, "name" => name, "label" => label, "open" => false}
  end

  def self.update(records, event)
    records.map do |record|
      if record["id"] == event["id"]
        record.merge({"name" => event["name"], "open" => event["open"]})
      else
        record
      end
    end
  end
end
