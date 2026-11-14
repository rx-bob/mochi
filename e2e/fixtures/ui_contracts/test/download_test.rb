require 'json'
require 'csv'
require_relative '../lib/RecordData'

records = (1..RecordData::COUNT).map { |index| RecordData.record(index) }
jsonl = ->(rows) { rows.map { |row| JSON.generate(row) + "\n" }.join }
csv = ->(rows) {
  "id,severity,message,source,sequence,timestamp\r\n" + rows.map do |row|
    detail = row['details']
    CSV.generate_line([row['id'], row['severity'], row['message'], detail['source'], detail['sequence'], detail['timestamp']],
      force_quotes: true, row_sep: "\r\n")
  end.join
}

Mochi::Test.test("downloads contain every filtered record, not only the visible page") do
  mount "inspector-root"
  download ".export-jsonl"
  assert_download filename: "records.jsonl", bytes: jsonl.call(records)
  assert_text ".export-status", "Downloaded 480 records as JSONL"
  download ".export-csv"
  assert_download filename: "records.csv", bytes: csv.call(records)
  fill ".filter", "Record 1"
  selected = records.select { |row| row['message'].include?('Record 1') }
  download ".export-jsonl"
  assert_download filename: "records.jsonl", bytes: jsonl.call(selected)
  click ".toggle-order"
  download ".export-csv"
  assert_download filename: "records.csv", bytes: csv.call(selected.reverse)
end

Mochi::Test.test("downloads preserve Unicode CSV quoting and empty filtered sets") do
  mount "inspector-root"
  fill ".filter", "café"
  download ".export-jsonl"
  assert_download filename: "records.jsonl", bytes: jsonl.call([records[41]])
  download ".export-csv"
  assert_download filename: "records.csv", bytes: csv.call([records[41]])
  fill ".filter", "no matching records"
  download ".export-jsonl"
  assert_download filename: "records.jsonl", bytes: ""
  download ".export-csv"
  assert_download filename: "records.csv", bytes: csv.call([])
end
