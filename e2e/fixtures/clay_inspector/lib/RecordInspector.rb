class RecordInspector
  @tag_name = "record-inspector"
  @records
  @selected
  @details

  def initialize
    @records = [
      {"id" => "01", "name" => "Harbor", "label" => " weather station"},
      {"id" => "02", "name" => "Café", "label" => " observation from the northern coastal monitoring station"},
      {"id" => "03", "name" => "West", "label" => " ridge sensor"}
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
      <div class="panel" data-view="panel">
        <span class="title" data-view="title">Station records Ω</span>
        <div class="actions" data-view="actions">
          <button class="action action-default action-fixed" data-action="reverse" onclick="{reverse_records}">Reverse order</button>
          <button class="action-default action" data-action="details" onclick="{toggle_details}">Details</button>
        </div>
        {each @records as record, key: record["id"]}
          <button class="{if @selected == record['id']}selected{end} record" aria-pressed="{@selected == record['id']}" data-id="{record['id']}" onclick="{select_record($event)}">{record["name"]}{record["label"]}</button>
        {end}
        <span class="selection" data-view="selection">Selected st&#97;tion {@selected}</span>
        {if @details}
          <span class="detail" data-view="details">Showing details for station {@selected}</span>
        {end}
      </div>
    }
  end

  def css
    %Q{
      @import "./styles/inspector.css";
      .panel {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
        background-color: #eff4f2;
        color: #162d27;
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 16px;
        line-height: 24px;
      }
      .title {
        font-weight: 700;
        font-size: 22px;
        line-height: 30px;
      }
      .actions {
        display: flex;
        flex-direction: row;
        gap: 8px;
      }
      .action {
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 14px;
        line-height: 20px;
        padding: 8px;
        border: 0;
        text-align: left;
        color: #ffffff;
        background-color: #26634f;
      }
      .action-fixed {
        width: 108px;
        height: 38px;
      }
      .record {
        width: auto;
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 16px;
        line-height: 24px;
        padding: 8px;
        border: 0;
        text-align: left;
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
