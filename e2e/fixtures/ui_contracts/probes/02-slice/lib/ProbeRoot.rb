
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @value = [1, 2, 3, 4].slice(1, 2).to_s
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
