
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = Time.now
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
