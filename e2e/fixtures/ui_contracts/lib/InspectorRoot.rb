class InspectorRoot
  @tag_name = "inspector-root"
  @records
  @visible_records
  @query
  @page
  @matched_count
  @selected_id
  @selected_detail

  def initialize
    @records = RecordData.build
    @query = ""
    @page = 0
    @selected_id = ""
    @selected_detail = "No selection"
    refresh_page
  end

  def refresh_page
    matches = RecordData.filter(@records, @query)
    @matched_count = matches.length
    last_page = @matched_count == 0 ? 0 : (@matched_count - 1) / RecordData::PAGE_SIZE
    @page = last_page if @page > last_page
    @page = 0 if @page < 0
    @visible_records = matches.slice(@page * RecordData::PAGE_SIZE, RecordData::PAGE_SIZE)
  end

  def filter
    @page = 0
    refresh_page
  end

  def next_page
    @page += 1
    refresh_page
  end

  def previous_page
    @page -= 1
    refresh_page
  end

  def select_record(event)
    id = event["current_target_dataset"]["id"]
    @selected_id = id
    @records.each do |record|
      if record["id"] == id
        detail = record["details"]
        @selected_detail = "#{detail["source"]}:#{detail["sequence"]}"
      end
    end
  end

  def html
    %Q{
      <h1>Record inspector</h1>
      <label>Literal message filter <input class="filter" oninput="{filter}" bind:value="{@query}"></label>
      <p>Total <span class="total">{@records.length}</span>; matching <span class="matched">{@matched_count}</span></p>
      <p>Page <span class="page">{@page + 1}</span>; visible <span class="visible-count">{@visible_records.length}</span></p>
      <button class="previous" onclick="{previous_page}">Previous</button>
      <button class="next" onclick="{next_page}">Next</button>
      <table><tbody>
        {each @visible_records as record, key: record["id"]}
          <tr class="record" data-id="{record['id']}" onclick="{select_record($event)}">
            <td><button><span class="message" data-part="message">{record["message"]}</span></button></td>
            <td class="severity">{record["severity"]}</td>
          </tr>
        {end}
      </tbody></table>
      <p>Selected <span class="selected-id">{@selected_id}</span></p>
      <p class="selected-detail">{@selected_detail}</p>
    }
  end
end
