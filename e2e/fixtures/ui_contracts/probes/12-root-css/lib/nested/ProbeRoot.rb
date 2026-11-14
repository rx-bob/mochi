
class ProbeRoot
  @tag_name = "probe-root"

  def css
    %Q{@import "../../styles/base.css";}
  end

  def html
    %Q{<div class="shared">Shared style</div><img src="/public/probe.svg">}
  end
end
