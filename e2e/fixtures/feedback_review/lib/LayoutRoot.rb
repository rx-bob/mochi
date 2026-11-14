class LayoutRoot
  @tag_name = "layout-root"
  def initialize
    @width = 0
    @keys = 0
  end
  def mounted
    MochiLayout.observe("viewport", "measured")
    MochiShortcuts.register("h", "shortcut")
  end
  def measured(result)
    @width = result["value"]["width"] if result["ok"]
  end
  def shortcut(result)
    @keys = @keys + 1 if result["ok"]
  end
  def html
    %Q{<div class="frame"><slow-panel></slow-panel><div ref="viewport" class="viewport"><button class="inside">Inside</button><output>{@width}</output><span class="keys">{@keys}</span></div></div>}
  end
  def css
    %Q{:host {display: contents;} .frame {display:flex; width:800px;} .viewport {flex:1;min-width:0;height:100px;}}
  end
end
