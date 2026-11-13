
class ProbeRoot
  @tag_name = "probe-root"

  @selected
  @current
  def initialize
    @selected = "initial"
    @current = "initial"
  end
  def select_row(event)
    @selected = event["dataset"]["id"].to_s
    @current = event["current_target_dataset"].to_s
  end

  def html
    %Q{<table><tbody><tr id="log-001" data-id="log-001" onclick="{select_row($event)}"><td><span>ERROR</span></td></tr></tbody></table><output class="selected">{@selected}</output><output class="current">{@current}</output>}
  end
end
