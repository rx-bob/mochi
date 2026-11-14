class NumericContractsRoot
  @tag_name = "numeric-contracts-root"
  @initial_value
  @event_value

  def initialize
    @initial_value = (-2.5).round
    @event_value = 0
  end

  def helper_value
    2.5.round(half: :even)
  end

  def update_value
    @event_value = (-1.25).floor(1)
  end

  def invalid_value
    1.5.round(19)
  end

  def html
    %Q{
      <span class="integer-round">{(-1.5).round}</span>
      <span class="float-round">{(1.25).round(1)}</span>
      <span class="float-type">{(2.0).round(1)}</span>
      <span class="negative-floor">{(-1.21).floor(1)}</span>
      <span class="initial-value">{@initial_value}</span>
      <span class="helper-round">{helper_value}</span>
      <span class="event-value">{@event_value}</span>
      <button class="update" onclick="{update_value}">Update</button>
      <button class="invalid" onclick="{invalid_value}">Invalid precision</button>
    }
  end
end
