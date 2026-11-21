class StationRow
  @tag_name = "station-row"

  prop :station_id, String, required: true
  prop :station_name, String, required: true
  prop :description, String, required: true
  prop :selected, Boolean, default: false

  event :select, id: String, name: String
  event :hide, id: String

  @expanded

  def initialize
    @expanded = false
  end

  def select_station
    @expanded = !@expanded if @selected
    emit :select, id: @station_id, name: @station_name
  end

  def hide_station
    emit :hide, id: @station_id
  end

  def html
    %Q{
      <button class="{if @selected}selected{end} record" tabindex="0" aria-pressed="{@selected}" aria-expanded="{@expanded}" data-id="{@station_id}" onclick="{select_station}">{@station_name}{@description}</button>
      {if @expanded}
        <button class="record" tabindex="0" data-row-action="hide" onclick="{hide_station}">Hide {@station_name}</button>
      {end}
    }
  end

  def css
    %Q{
      .record {
        width: auto;
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 16px;
        line-height: 24px;
        color: #162d27;
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
