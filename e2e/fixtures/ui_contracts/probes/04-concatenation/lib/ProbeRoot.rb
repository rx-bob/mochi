
class ProbeRoot
  @tag_name = "probe-root"

  @data
  def initialize
    out = ""
    index = 0
    while index < 360
      out = out + "record #{index}: processed deterministic local event with nested details" + "\n"
      index += 1
    end
    @data = out
  end

  def html
    %Q{<output>{@data.length}</output>}
  end
end
