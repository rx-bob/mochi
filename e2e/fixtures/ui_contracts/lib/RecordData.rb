module RecordData
  BASE = 1794571200000
  COUNT = 480
  PAGE_SIZE = 12

  def self.base_ms
    BASE
  end

  def self.record(index)
    {
      "id" => "record-#{index}",
      "severity" => index % 3 == 0 ? "warning" : "info",
      "message" => index == 42 ? "Record 42 processed — café, \"quoted\"\nnext line" : "Record #{index} processed",
      "details" => {"source" => "worker-#{index % 4}", "sequence" => index,
                    "timestamp" => BASE + index,
                    "attributes" => [{"name" => "region", "value" => "zone-#{index % 3}"},
                                     {"name" => "attempt", "value" => index % 5 + 1}]}
    }
  end

  def self.filter(records, query)
    matches = []
    records.each do |record|
      next if !record["message"].include?(query)
      matches << record
    end
    matches
  end

  def self.find(records, id)
    found = nil
    records.each { |record| found = record if record["id"] == id }
    found
  end

  def self.ordered(records, newest_first)
    records.sort_by do |record|
      milliseconds = record["details"]["timestamp"]
      newest_first ? -milliseconds : milliseconds
    end
  end

  def self.instant(record)
    Time.at(record["details"]["timestamp"] / 1000.0)
  end

  def self.display_instant(record, zone)
    MochiFormat.timestamp(instant(record).utc.to_f, "en-GB", zone,
      {"year" => "numeric", "month" => "2-digit", "day" => "2-digit",
       "hour" => "2-digit", "minute" => "2-digit", "second" => "2-digit",
       "fractional_second_digits" => 3, "hour_cycle" => "h23"})
  end
end
