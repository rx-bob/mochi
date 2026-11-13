class ProbeRoot
  @tag_name = "probe-root"
  @selected
  @target
  @part
  @current
  @calls
  @target_padding
  @handler_padding

  def initialize
    @selected = "initial"
    @target = "initial"
    @part = "initial"
    @current = "initial"
    @calls = 0
    reset_data
  end

  def select_row(event)
    @selected = event["dataset"]["id"].to_s
    @target = event["target_dataset"]["id"].to_s
    @part = event["target_dataset"]["part"].to_s
    @current = event["current_target_dataset"]["id"]
    @calls += 1
  end

  def oversize_target
    @target_padding = "x" * 9000
  end

  def oversize_handler
    @handler_padding = "x" * 9000
  end

  def reset_data
    @target_padding = ""
    @handler_padding = ""
  end

  def html
    %Q{
      <button class="oversize-target" onclick="{oversize_target}">Large target data</button>
      <button class="oversize-handler" onclick="{oversize_handler}">Large handler data</button>
      <button class="reset" onclick="{reset_data}">Reset data</button>
      <table><tbody><tr data-id="log-001" data-padding="{@handler_padding}" onclick="{select_row($event)}"><td><span data-part="label" data-padding="{@target_padding}">ERROR</span></td></tr></tbody></table>
      <output class="selected">{@selected}</output><output class="target">{@target}</output>
      <output class="part">{@part}</output><output class="current">{@current}</output><output class="calls">{@calls}</output>
    }
  end
end
