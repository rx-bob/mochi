require 'time'
class ProbeRoot
  @tag_name = "probe-root"

  @value
  @input
  @now
  computed :instant, depends_on: [:@input]
  computed :clock_in_computed, depends_on: [:@input]

  def initialize
    @input = 1.25
    @now = ""
    valid
  end

  def instant
    Time.at(@input)
  end

  def clock_in_computed
    Time.now
  end

  def read_clock_in_computed
    @value = clock_in_computed
  end

  def valid
    value = Time.at(-1.25)
    @value = "#{value.to_f}:#{value.to_i}:#{value.utc == value}"
  end

  def capture_now
    value = Time.now.utc
    @now = "#{value.to_f}:#{value.to_i}"
  end

  def update
    @input = -0.125
  end

  def wrong_type
    @value = Time.at("1")
  end

  def nonfinite
    @value = Time.at(1.0 / 0.0)
  end

  def out_of_range
    @value = Time.at(8640000000001)
  end

  def extra_arguments
    @value = Time.at(1, 2)
  end

  def calendar_constructor
    @value = Time.new(2026, 11, 13)
  end

  def invalid_zone
    @value = MochiFormat.timestamp(0, "en-GB", "not/a-zone")
  end

  def roundtrips
    [0, -1.25, 0.0001, 1794571200.123, -8640000000000, 8640000000000].map do |seconds|
      value = Time.at(seconds)
      Time.at(value.to_f).to_f == value.to_f
    end.join(",")
  end

  def html
    %Q{
      <output>{@value}</output><span class="computed">{instant.to_f}:{instant.to_i}</span>
      <span class="now">{@now}</span>
      <span class="roundtrips">{roundtrips}</span>
      <span class="bounds">{Time.at(-8640000000000).to_i}:{Time.at(8640000000000).to_i}</span>
      <button class="valid" onclick="{valid}">Valid</button>
      <button class="now-button" onclick="{capture_now}">Now</button>
      <button class="update" onclick="{update}">Update</button>
      <button class="wrong-type" onclick="{wrong_type}">Wrong type</button>
      <button class="nonfinite" onclick="{nonfinite}">Nonfinite</button>
      <button class="out-of-range" onclick="{out_of_range}">Out of range</button>
      <button class="extra-arguments" onclick="{extra_arguments}">Extra arguments</button>
      <button class="calendar-constructor" onclick="{calendar_constructor}">Calendar</button>
      <button class="invalid-zone" onclick="{invalid_zone}">Invalid zone</button>
      <button class="computed-clock" onclick="{read_clock_in_computed}">Computed clock</button>
    }
  end
end
