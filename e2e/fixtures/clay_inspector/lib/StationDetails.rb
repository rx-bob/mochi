class StationDetails
  @tag_name = "station-details"

  prop :station_id, Integer, required: true
  prop :station_name, String, required: true
  prop :metadata, Hash, required: true
  prop :prefix, String, default: "Showing details for station"

  event :confirm, id: Integer, name: String

  @opened
  @confirmations

  def initialize
    @opened = "#{@prefix} #{@station_id + 100}: #{@metadata["note"][0]}"
    @confirmations = 0
    # mochi-lint: disable-next components/prop-write -- exercise the constructor's independent snapshot
    @metadata["note"][0] = "constructor"
    # mochi-lint: disable-next components/prop-write -- verify parent input is restored after initialize
    @station_id = 0
  end

  def confirm
    @confirmations += 1
    # mochi-lint: disable-next components/prop-write -- exercise deep collection isolation from the parent
    @metadata["note"][0] = "child"
    emit :confirm, id: @station_id, name: @station_name
  end

  def station_pair
    "#{@station_id}: #{@station_name}"
  end

  def html
    %Q{
      <div class="detail-panel">
        <span class="detail-heading" data-view="details">{@prefix} {StationNumbers.label(@station_id)}</span>
        <div class="detail-body">
          <span data-detail="pair">{station_pair}</span>
          <span data-detail="opened">{@opened}</span>
          <span data-detail="snapshot">{@metadata["note"][0]} / {@confirmations}</span>
          <button class="confirm" data-detail="confirm" onclick="{confirm}">Confirm station</button>
        </div>
      </div>
    }
  end

  def css
    %Q{
      @import "./styles/details.css";
      .detail-panel {
        background-color: #d3e8de;
        color: #162d27;
        font-family: StationSans, StationSymbols, sans-serif;
        font-size: 16px;
        line-height: 24px;
      }
      .detail-heading {
        padding: 8px;
      }
      .detail-body {
        display: flex;
        flex-direction: column;
        gap: 4px;
        padding: 8px;
      }
    }
  end
end
