class ProbeRoot
  @tag_name = "probe-root"
  @values
  @initial
  @stored_initial
  @event
  @alias
  @big
  @last

  def initialize
    @values = [1, 2, 3, 4]
    @initial = [1, 2, 3, 4].slice(1, 2).join(",")
    @stored_initial = @values[1, 2].join(",")
    @event = "not called"
    @big = []
    @last = "unchanged"
    nested = [{"value" => 7}]
    part = nested.slice(0, 1)
    part[0]["value"] = 9
    part[0] = nil
    @alias = nested[0]["value"]
  end

  def window(array)
    array.[](1, 2)
  end

  def show(value)
    value == nil ? "nil" : "#{value.length}:#{value.join(',')}"
  end

  def boundaries
    pairs = [[1, 2], [-2, 9], [-4, 2], [-5, 2], [0, -1], [1, 0],
             [4, 2], [4, 0], [5, 0], [0, 9223372036854775807],
             [-9223372036854775807 - 1, 2]]
    results = []
    pairs.each do |pair|
      results << show(@values.slice(pair[0], pair[1]))
      results << show(@values[pair[0], pair[1]])
    end
    results.join("|")
  end

  def valid
    @event = @values.slice(-2, 9).join(",")
  end

  def no_args
    @values.slice
  end

  def extra_args
    @values[0, 1, 2]
  end

  def bad_start
    @values["1"]
  end

  def bad_length
    @values.slice(1, "2")
  end

  def bad_scalar
    @values.slice(nil)
  end

  def prepare_big
    @big = []
    index = 0
    while index < 5000
      @big << index
      index += 1
    end
  end

  def exhaust_slice
    @last = @big.slice(0, 5000).join(",")
  end

  def small_slice
    @last = @big[4998, 2].join(",")
  end

  def html
    %Q{
      <output class="initial">{@initial}</output>
      <output class="stored-initial">{@stored_initial}</output>
      <output class="helper">{window(@values).join(',')}</output>
      <output class="template">{@values.slice(1, 2).join(',')}</output>
      <output class="scalar">{@values[0]}:{@values[-1]}:{@values.slice(1)}</output>
      <output class="original">{@values.join(',')}</output>
      <output class="alias">{@alias}</output>
      <output class="boundaries">{boundaries}</output>
      <output class="event">{@event}</output>
      <output class="big-count">{@big.length}</output>
      <output class="last">{@last}</output>
      <button class="valid" onclick="{valid}">Valid</button>
      <button class="no-args" onclick="{no_args}">No arguments</button>
      <button class="extra-args" onclick="{extra_args}">Extra arguments</button>
      <button class="bad-start" onclick="{bad_start}">Bad start</button>
      <button class="bad-length" onclick="{bad_length}">Bad length</button>
      <button class="bad-scalar" onclick="{bad_scalar}">Bad scalar</button>
      <button class="prepare-big" onclick="{prepare_big}">Prepare</button>
      <button class="exhaust" onclick="{exhaust_slice}">Exhaust slice</button>
      <button class="small" onclick="{small_slice}">Small slice</button>
    }
  end
end
