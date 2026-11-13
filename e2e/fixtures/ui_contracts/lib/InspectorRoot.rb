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
    @records = []
    index = 1
    while index <= 48
      @records << {
        "id" => "record-#{index}",
        "severity" => index % 3 == 0 ? "warning" : "info",
        "message" => "Record #{index} processed",
        "details" => {"source" => "worker-#{index % 4}", "sequence" => index}
      }
      index += 1
    end
    @query = ""
    @page = 0
    @selected_id = ""
    @selected_detail = "No selection"
    refresh_page
  end

  def refresh_page
    matches = @records.select { |record| record["message"].include?(@query) }
    @matched_count = matches.length
    last_page = @matched_count == 0 ? 0 : (@matched_count - 1) / 12
    @page = last_page if @page > last_page
    @page = 0 if @page < 0
    @visible_records = matches.slice(@page * 12, 12)
  end

  def filter(event)
    @query = event["value"]
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

  def select_record(id)
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
      <label>Literal message filter <input class="filter" oninput="{filter($event)}"></label>
      <p>Total <span class="total">{@records.length}</span>; matching <span class="matched">{@matched_count}</span></p>
      <p>Page <span class="page">{@page + 1}</span>; visible <span class="visible-count">{@visible_records.length}</span></p>
      <button class="previous" onclick="{previous_page}">Previous</button>
      <button class="next" onclick="{next_page}">Next</button>
      <ol>
        {each @visible_records as record, key: record["id"]}
          <li class="record" data-id="{record['id']}">
            <button onclick="{select_record(record['id'])}"><span class="message">{record["message"]}</span></button>
            <span class="severity">{record["severity"]}</span>
          </li>
        {end}
      </ol>
      <p>Selected <span class="selected-id">{@selected_id}</span></p>
      <p class="selected-detail">{@selected_detail}</p>
    }
  end
end
