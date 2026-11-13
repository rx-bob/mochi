
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = RecordData::BASE
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
