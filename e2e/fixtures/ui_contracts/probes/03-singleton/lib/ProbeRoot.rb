
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = RecordData.base_ms
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
