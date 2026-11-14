
class ProbeRoot
  @tag_name = "probe-root"

  @value
  def initialize
    @data = "alpha\n\nbeta"
    list = []
    @data.split("\n").each do |line|
      next if line == ""
      list << line
    end
    @value = list.join(",")
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
