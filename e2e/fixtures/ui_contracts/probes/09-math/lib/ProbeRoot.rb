
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = Math.sqrt(4)
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
