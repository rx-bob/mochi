
class ProbeRoot
  @tag_name = "probe-root"

  @modal
  @node
  def initialize
    @modal = {"title" => "Open record"}
    @node = {"ghost" => true}
  end

  def html
    %Q{<div aria-label="{@modal["title"]}" class="{if @node["ghost"]}ghost{end}">{@modal["title"]}</div>}
  end
end
