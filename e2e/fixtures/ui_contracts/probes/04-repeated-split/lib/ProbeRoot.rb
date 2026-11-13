
class ProbeRoot
  @tag_name = "probe-root"

  @data
  def initialize
    lines = []
    index = 0
    while index < 480
      lines << "record-#{index}"
      index += 1
    end
    @data = lines.join("\n")
  end
  def filtered_lines
    @data.split("\n")
  end

  def html
    %Q{<output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output><output>{filtered_lines.length}</output>}
  end
end
