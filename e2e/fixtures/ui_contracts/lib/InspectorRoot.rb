require 'json'

# mochi-lint: disable-next metrics/class-variables -- fixture keeps the full inspector state in one component to prove paging, filtering, and download behavior
class InspectorRoot
  @tag_name = "inspector-root"
  @records
  @query
  @page
  @selected_id
  @next_sequence
  @show_details
  @json_sample
  @json_roundtrip
  @newest_first
  @display_zone
  @export_parts
  @export_status

  computed :ordered_records, depends_on: [:@records, :@newest_first]
  computed :filtered_records, depends_on: [:ordered_records, :@query]
  computed :visible_records, depends_on: [:filtered_records, :@page]
  computed :selected_record, depends_on: [:@records, :@selected_id]
  computed :detail_fields, depends_on: [:selected_record]
  computed :selected_detail, depends_on: [:selected_record]

  def initialize
    # Each completed record becomes durable before constructing the next.
    @records = []
    index = 1
    while index <= RecordData::COUNT
      @records << RecordData.record(index)
      index += 1
    end
    @query = ""
    @page = 0
    @selected_id = ""
    @next_sequence = RecordData::COUNT + 1
    @show_details = true
    @json_sample = ""
    @json_roundtrip = ""
    @newest_first = false
    @display_zone = "UTC"
    @export_parts = []
    @export_status = ""
  end

  def export_jsonl
    @export_parts = []
    filtered_records.each { |record| @export_parts << JSON.generate(record) + "\n" }
    parts = @export_parts
    @export_parts = []
    MochiDownload.save("records.jsonl", "application/x-ndjson;charset=utf-8", parts)
    @export_status = "Downloaded #{parts.length} records as JSONL"
  end

  def export_csv
    @export_parts = ["id,severity,message,source,sequence,timestamp\r\n"]
    filtered_records.each do |record|
      detail = record["details"]
      fields = [record["id"], record["severity"], record["message"], detail["source"], detail["sequence"], detail["timestamp"]]
      @export_parts << fields.map { |field| '"' + field.to_s.gsub('"', '""') + '"' }.join(",") + "\r\n"
    end
    parts = @export_parts
    @export_parts = []
    MochiDownload.save("records.csv", "text/csv;charset=utf-8", parts)
    @export_status = "Downloaded #{parts.length - 1} records as CSV"
  end

  def ordered_records
    RecordData.ordered(@records, @newest_first)
  end

  def toggle_order
    @newest_first = !@newest_first
    @page = 0
  end

  def toggle_zone
    @display_zone = @display_zone == "UTC" ? "Asia/Tokyo" : "UTC"
  end

  def selected_time
    record = selected_record
    record.nil? ? "" : RecordData.display_instant(record, @display_zone)
  end

  def parse_sample
    sample = JSON.parse('{"id":9007199254740993,"tags":["ruby",null,true],"meta":{"ok":false}}')
    @json_sample = "#{sample['id']}:#{sample['tags'][0]}:#{sample['tags'][1].nil?}:#{sample['meta']['ok']}"
  end

  def roundtrip_selected
    record = selected_record
    return if record.nil?
    encoded = JSON.generate(record)
    restored = JSON.parse(encoded)
    @json_roundtrip = "#{restored['id']}:#{restored['details']['timestamp']}:#{JSON.generate(restored) == encoded}"
  end

  def filtered_records
    RecordData.filter(ordered_records, @query)
  end

  def visible_records
    filtered_records.slice(@page * RecordData::PAGE_SIZE, RecordData::PAGE_SIZE)
  end

  def last_page
    count = filtered_records.length
    count == 0 ? 0 : (count - 1) / RecordData::PAGE_SIZE
  end

  def selected_record
    RecordData.find(@records, @selected_id)
  end

  def detail_fields
    record = selected_record
    record.nil? ? [] : record["details"]["attributes"]
  end

  def selected_detail
    record = selected_record
    return "No selection" if record.nil?
    detail = record["details"]
    "#{detail['source']}:#{detail['sequence']}"
  end

  def selected_message
    record = selected_record
    record.nil? ? "" : record["message"]
  end

  def selected_timestamp
    record = selected_record
    record.nil? ? "" : record["details"]["timestamp"].to_s
  end

  def filter
    @page = 0
  end

  def next_page
    @page += 1 if @page < last_page
  end

  def previous_page
    @page -= 1 if @page > 0
  end

  def select_record(event)
    @selected_id = event["current_target_dataset"]["id"]
  end

  def append_record
    record = RecordData.record(@next_sequence)
    dropped_id = @records.length == RecordData::COUNT ? @records[0]["id"] : ""
    retained = @records.length == RecordData::COUNT ? @records.slice(1, RecordData::COUNT - 1) : @records
    @records = retained + [record]
    @next_sequence += 1
    @selected_id = "" if @selected_id == dropped_id
    @page = last_page if @page > last_page
  end

  def remove_selected
    return if @selected_id == ""
    @records = @records.reject { |record| record["id"] == @selected_id }
    @selected_id = ""
    @page = last_page if @page > last_page
  end

  def toggle_details
    @show_details = !@show_details
  end

  def html
    %Q{
      <h1>Record inspector</h1>
      <label>Literal message filter <input class="filter" oninput="{filter}" bind:value="{@query}"></label>
      <p>Total <span class="total">{@records.length}</span>; matching <span class="matched">{filtered_records.length}</span></p>
      <p>Page <span class="page">{@page + 1}</span>; visible <span class="visible-count">{visible_records.length}</span></p>
      <button class="previous" onclick="{previous_page}">Previous</button>
      <button class="next" onclick="{next_page}">Next</button>
      <button class="append" onclick="{append_record}">Append record</button>
      <button class="remove-selected" onclick="{remove_selected}">Remove selected</button>
      <button class="toggle-details" onclick="{toggle_details}">Toggle details</button>
      <button class="toggle-order" onclick="{toggle_order}">Reverse chronological order</button>
      <button class="toggle-zone" onclick="{toggle_zone}">Switch UTC / Tokyo</button>
      <span class="display-zone">{@display_zone}</span>
      <button class="parse-json" onclick="{parse_sample}">Parse JSON sample</button>
      <button class="roundtrip-json" onclick="{roundtrip_selected}">Round-trip selected record</button>
      <button class="export-jsonl" onclick="{export_jsonl}">Download filtered JSONL</button>
      <button class="export-csv" onclick="{export_csv}">Download filtered CSV</button>
      <output class="export-status">{@export_status}</output>
      <output class="json-sample">{@json_sample}</output>
      <output class="json-roundtrip">{@json_roundtrip}</output>
      <table><tbody>
        {each visible_records as record, key: record["id"]}
          <tr class="record" data-id="{record['id']}" onclick="{select_record($event)}">
            <td><button><span class="message" data-part="message">{record["message"]}</span></button></td>
            <td class="severity">{record["severity"]}</td>
          </tr>
        {end}
      </tbody></table>
      <p>Selected <span class="selected-id">{@selected_id}</span></p>
      {if @show_details}
        <p class="selected-detail">{selected_detail}</p>
        <p class="selected-message">{selected_message}</p>
        <p class="selected-timestamp">{selected_timestamp}</p>
        <p class="selected-time">{selected_time}</p>
        <dl>
          {each detail_fields as field, key: field["name"]}
            <div class="detail-field" data-name="{field['name']}"><dt>{field["name"]}</dt><dd>{field["value"]}</dd></div>
          {end}
        </dl>
      {else}
        <p class="details-hidden">Details hidden</p>
      {end}
    }
  end
end
