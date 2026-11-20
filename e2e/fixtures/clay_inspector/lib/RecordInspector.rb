class RecordInspector
  @tag_name = "record-inspector"
  @records
  @selected
  @details

  def initialize
    @records = [
      {"id" => "01", "label" => "Harbor weather station"},
      {"id" => "02", "label" => "Café observation from the northern coastal monitoring station"},
      {"id" => "03", "label" => "West ridge sensor"}
    ]
    @selected = "01"
    @details = false
  end

  def select_record(event)
    @selected = event["current_target_dataset"]["id"]
  end

  def reverse_records
    @records = @records.reverse
  end

  def toggle_details
    @details = !@details
  end

  def html
    %Q{
      <div class="panel">
        <span class="title">Station records</span>
        <div class="actions">
          <button class="action" data-action="reverse" onclick="{reverse_records}">Reverse order</button>
          <button class="action" data-action="details" onclick="{toggle_details}">Details</button>
        </div>
        {each @records as record, key: record["id"]}
          <button class="record {if @selected == record['id']}selected{end}" aria-pressed="{@selected == record['id']}" data-id="{record['id']}" onclick="{select_record($event)}">{record["label"]}</button>
        {end}
        <span class="selection" data-view="selection">Selected station {@selected}</span>
        {if @details}
          <span class="detail" data-view="details">Showing details for station {@selected}</span>
        {end}
      </div>
    }
  end

  def css
    %Q{
      .panel {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
        background-color: #eff4f2;
        color: #162d27;
        font-family: StationSans, sans-serif;
        font-size: 16px;
        line-height: 24px;
      }
      .title {
        font-size: 22px;
        line-height: 30px;
      }
      .actions {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .action {
        font-family: StationSans, sans-serif;
        font-size: 14px;
        line-height: 20px;
        padding: 8px;
        border: 0;
        text-align: left;
        color: #ffffff;
        background-color: #26634f;
      }
      .record {
        font-family: StationSans, sans-serif;
        font-size: 16px;
        line-height: 24px;
        padding: 8px;
        border: 0;
        text-align: left;
        color: #162d27;
        background-color: #ffffff;
      }
      .selected {
        background-color: #c9e7d9;
      }
      .detail {
        padding: 8px;
        background-color: #d3e8de;
      }
    }
  end
end
