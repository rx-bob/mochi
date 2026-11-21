class RecordInspector
  @tag_name = "record-inspector"
  @records
  @first_stations
  @more
  @list_action
  @selected
  @details
  @station_name
  @metadata
  @confirmations
  @confirmation

  def initialize
    @first_stations = [
      {"id" => "01", "name" => "Harbor", "label" => " weather station"},
      {"id" => "02", "name" => "Café", "label" => " observation from the northern coastal monitoring station"},
      {"id" => "03", "name" => "West", "label" => " ridge sensor"}
    ]
    @records = @first_stations
    @more = false
    @list_action = "Show more stations"
    @selected = "01"
    @station_name = "Harbor"
    @metadata = {"note" => ["parent"]}
    @confirmations = 0
    @confirmation = "No station confirmed"
    @details = false
  end

  def select_record(event)
    dataset = event["current_target_dataset"]
    @selected = dataset["id"]
    @station_name = dataset["name"]
  end

  def reverse_records
    @records = @records.reverse
  end

  def toggle_stations
    @more = !@more
    @list_action = @more ? "Show fewer stations" : "Show more stations"
    @records = @first_stations
    return unless @more

    extra = []
    number = 10
    while number <= 24
      id = number.to_s
      extra << {"id" => id, "name" => "Station #{id}", "label" => " monitoring point"}
      number += 1
    end
    @records = @records + extra
  end

  def toggle_details
    @details = !@details
  end

  def confirm_station(event)
    @confirmations += 1
    @confirmation = "#{event["id"] + 100}: #{event["name"]} / #{@confirmations} / #{@metadata["note"][0]}"
  end

  def html
    %Q{
      <div class="panel" data-view="panel">
        <span class="title" data-view="title">Station records Ω</span>
        <div class="actions" data-view="actions">
          <button class="action action-default action-fixed" data-action="reverse" onclick="{reverse_records}">Reverse order</button>
          <button class="action-default action" data-action="details" onclick="{toggle_details}">Details</button>
        </div>
        <div class="stations" data-scroll="stations">
          {each @records as record, key: record["id"]}
            <button class="{if @selected == record['id']}selected{end} record" tabindex="0" aria-pressed="{@selected == record['id']}" data-id="{record['id']}" data-name="{record['name']}" onclick="{select_record($event)}">{record["name"]}{record["label"]}</button>
          {end}
        </div>
        <span class="selection" data-view="selection">Selected st&#97;tion {@selected}</span>
        <button class="action" data-list="toggle" onclick="{toggle_stations}">{@list_action}</button>
        {if @details}
          <station-details station-id="{StationNumbers.id(@selected)}" station-name="{@station_name}" metadata="{@metadata}" on:confirm="{confirm_station($event)}"></station-details>
          <span data-confirmation="status">{@confirmation}</span>
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
      @container (max-width: 315px) {
        .actions {
          flex-direction: column;
        }
      }
      .stations {
        display: flex;
        flex-direction: column;
        gap: 8px;
        max-height: 200px;
        overflow-y: auto;
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
    }
  end
end
