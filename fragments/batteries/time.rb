# UTC instants. Unix seconds throughout; the browser clock supplies milliseconds.
class Time
  def self.now
    Time.at(Mochi.time_now / 1000.0)
  end

  def self.at(seconds)
    Mochi.time_at(seconds)
  end

  def to_i
    @seconds.floor
  end

  def to_f
    @seconds.to_f
  end

  def utc
    self
  end
end
