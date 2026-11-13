
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = JSON.parse('{"id":1}')
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
