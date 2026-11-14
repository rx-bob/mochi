class LayoutRoot
  @tag_name = "layout-root"
  def initialize
    @width = 0
    @height = 0
    @center_x = 0.0
    @center_y = 0.0
    @keys = 0
    @show_panel = true
  end
  def mounted
    MochiLayout.observe("viewport", "measured")
    MochiShortcuts.register("h", "shortcut")
  end
  def measured(result)
    if result["ok"]
      geometry = result["value"]
      @width = geometry["width"]
      @height = geometry["height"]
      @center_x = geometry["left"] + geometry["width"] / 2
      @center_y = geometry["top"] + geometry["height"] / 2
    end
  end
  def remove_panel
    @show_panel = false
  end
  def shortcut(result)
    @keys = @keys + 1 if result["ok"]
  end
  def html
    %Q{<div class="frame">{if @show_panel}<slow-panel></slow-panel>{end}<div ref="viewport" class="viewport"><button class="inside">Inside</button><button class="remove-panel" onclick="{remove_panel}">Remove panel</button><output class="geometry" data-width="{@width}" data-height="{@height}" data-center-x="{@center_x}" data-center-y="{@center_y}">{@width}</output><span class="keys">{@keys}</span></div></div>}
  end
  def css
    %Q{:host {display: contents;} .frame {display:flex; width:800px;} .viewport {flex:1;min-width:0;height:100px;}}
  end
end
