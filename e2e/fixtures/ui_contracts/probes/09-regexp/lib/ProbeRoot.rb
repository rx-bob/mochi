
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = Regexp.new("record")
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
