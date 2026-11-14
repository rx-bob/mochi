class SlowPanel
  @tag_name = "slow-panel"
  def html
    %Q{<p>Panel</p>}
  end
  def css
    %Q{:host {display:block;width:200px;flex-shrink:0;}}
  end
end
