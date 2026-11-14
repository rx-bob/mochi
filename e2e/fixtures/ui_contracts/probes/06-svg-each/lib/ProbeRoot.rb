
class ProbeRoot
  @tag_name = "probe-root"

  @edges
  def initialize
    @edges = [{"id" => "a", "path" => "M 0 0 L 20 20"}, {"id" => "b", "path" => "M 20 20 L 40 0"}]
  end

  def html
    %Q{<svg viewBox="0 0 40 40">{each @edges as edge, key: edge["id"]}<path d="{edge['path']}"></path>{end}</svg>}
  end
end
