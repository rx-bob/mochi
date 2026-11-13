
class ProbeRoot
  @tag_name = "probe-root"

  @rows
  @open
  def initialize
    @open = true
    @rows = [{"id" => "a", "name" => "Alpha", "selected" => true, "visible" => true}]
  end

  def html
    %Q{<table><tbody>{each @rows as row}
<tr class="{if row['selected']}selected{end}">{if row['visible']}<td>{row["name"]}</td>{end}</tr>
{end}</tbody></table>}
  end
end
