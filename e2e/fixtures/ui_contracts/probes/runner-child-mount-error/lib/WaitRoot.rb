class WaitRoot
  @tag_name = "wait-root"

  def initialize
    @show = false
  end

  def toggle
    @show = !@show
  end

  def html
    %Q{<main><button class="toggle" onclick="{toggle}">Show</button>{if @show}<failing-child></failing-child>{end}</main>}
  end
end
