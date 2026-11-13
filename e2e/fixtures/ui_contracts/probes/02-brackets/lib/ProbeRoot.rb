
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    arr = [1, 2, 3, 4]
    @value = arr[1, 2].to_s
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
