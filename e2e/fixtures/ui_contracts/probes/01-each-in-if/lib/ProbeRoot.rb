
class ProbeRoot
  @tag_name = "probe-root"

  @rows
  @open
  def initialize
    @open = true
    @rows = [{"id" => "a", "name" => "Alpha", "selected" => true, "visible" => true}]
  end

  def html
    %Q{{if @open}{each @rows as row}<div>{row["name"]}</div>{end}{end}}
  end
end
