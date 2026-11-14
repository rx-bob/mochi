class ClockRoot
  @tag_name = "clock-root"
  @instant

  def initialize
    @instant = Time.now.utc
  end

  def html
    %Q{<span class="mounted-now">{@instant.to_f}:{@instant.to_i}</span>}
  end
end
