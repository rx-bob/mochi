class InspectorRoot
  @tag_name = "inspector-root"
  @records
  @query
  @page
  @selected_id
  @next_sequence
  @show_details

  computed :filtered_records, depends_on: [:@records, :@query]
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
  end

  def filtered_records
    RecordData.filter(@records, @query)
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
