class RecordInspector
  @tag_name = "record-inspector"
  @records
  @first_stations
  @more
  @selected
  @details
  @current
  @editing
  @metadata
  @confirmations
  @confirmation

  def initialize
    @first_stations = [
      StationRecords.read("01", "Harbor", " weather station"),
      StationRecords.read("02", "Café", " observation from the northern coastal monitoring station"),
      StationRecords.read("03", "West", " ridge sensor")
    ]
    @records = @first_stations
    @more = false
    @selected = "01"
    @current = @records[0]
    @editing = nil
    @metadata = {"note" => ["parent"]}
    @confirmations = 0
    @confirmation = "No station confirmed"
    @details = false
  end

  def select_record(event)
    @selected = event["id"]
    @current = @records.find { |record| record["id"] == @selected }
  end

  def hide_record(event)
    hidden_id = event["id"]
    @records = @records.select { |record| record["id"] != hidden_id }
  end

  def reverse_records
    @records = @records.reverse
  end

  def toggle_stations
    @more = !@more
    @records = @first_stations
    return unless @more

    extra = []
    number = 10
    while number <= 24
      id = number.to_s
      extra << StationRecords.read(id, "Station #{id}", " monitoring point")
      number += 1
    end
    @records = @records + extra
  end

  def list_action
    @more ? "Show fewer stations" : "Show more stations"
  end

  def toggle_details
    @details = !@details
  end

  def confirm_station(event)
    @confirmations += 1
    @confirmation = "#{event["id"] + 100}: #{event["name"]} / #{@confirmations} / #{@metadata["note"][0]}"
  end

  def edit_station
    @editing = @current
    @details = false
  end

  def close_editor
    @editing = nil
    Mochi.focus(:edit_station)
  end

  def station_saved(event)
    @first_stations = StationRecords.update(@first_stations, event)
    @records = StationRecords.update(@records, event)
    if @selected == event["id"]
      @current = @current.merge({"name" => event["name"], "open" => event["open"]})
    end
    close_editor
  end

  def html
    %Q{
      <div class="panel" data-view="panel">
        <span class="title" data-view="title">Station records Ω</span>
        <div class="actions" data-view="actions">
          <button class="action action-default action-fixed" data-action="reverse" onclick="{reverse_records}">Reverse order</button>
          <button class="action-default action {if @editing}inactive{end}" data-action="details" disabled="{@editing != nil}" onclick="{toggle_details}">Details</button>
          <button class="action {if @editing}inactive{end}" data-action="edit" ref="edit_station" tabindex="0" disabled="{@editing != nil}" onclick="{edit_station}">Edit station</button>
        </div>
        {if @editing}
          <station-editor station-id="{@editing["id"]}" station-name="{@editing["name"]}" public-access="{@editing["open"]}" on:saved="{station_saved($event)}" on:cancelled="{close_editor}"></station-editor>
        {end}
        <div class="stations" data-scroll="stations">
          {each @records as record, key: record["id"]}
            <station-row data-station="{record['id']}" station-id="{record['id']}" station-name="{record['name']}" description="{record['label']}" selected="{@selected == record['id']}" on:select="{select_record($event)}" on:hide="{hide_record($event)}"></station-row>
          {end}
        </div>
        <span class="selection" data-view="selection">Selected st&#97;tion {@selected}</span>
        <button class="action" data-list="toggle" onclick="{toggle_stations}">{list_action}</button>
        {if @details}
          <station-details station-id="{StationNumbers.id(@selected)}" station-name="{@current["name"]}" metadata="{@metadata}" on:confirm="{confirm_station($event)}"></station-details>
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
      .inactive {
        color: #344940;
        background-color: #c1d4ca;
      }
    }
  end
end
