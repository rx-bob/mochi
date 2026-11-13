
class ProbeRoot
  @tag_name = "probe-root"

  def css
    %Q{@import "missing.css";}
  end

  def html
    %Q{<div>Missing style</div>}
  end
end
