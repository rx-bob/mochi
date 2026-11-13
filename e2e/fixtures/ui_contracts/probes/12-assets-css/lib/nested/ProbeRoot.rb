
class ProbeRoot
  @tag_name = "probe-root"

  def css
    %Q{@import "../themes/base.css";}
  end

  def html
    %Q{<span class="icon">{Mochi.raw(MochiIcons.icon("home"))}</span><div class="shared">Shared style</div><img src="/public/probe.svg">}
  end
end
