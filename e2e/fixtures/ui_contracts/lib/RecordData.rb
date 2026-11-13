module RecordData
  BASE = 1794571200000
  COUNT = 48
  PAGE_SIZE = 12

  def self.base_ms
    BASE
  end

  def self.build
    records = []
    index = 1
    while index <= COUNT
      records << {
        "id" => "record-#{index}",
        "severity" => index % 3 == 0 ? "warning" : "info",
        "message" => "Record #{index} processed",
        "details" => {"source" => "worker-#{index % 4}", "sequence" => index,
                      "timestamp" => BASE + index}
      }
      index += 1
    end
    records
  end

  def self.filter(records, query)
    matches = []
    records.each do |record|
      next if !record["message"].include?(query)
      matches << record
    end
    matches
  end
end
