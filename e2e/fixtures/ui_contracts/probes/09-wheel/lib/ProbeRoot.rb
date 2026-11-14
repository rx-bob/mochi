
class ProbeRoot
  @tag_name = "probe-root"

  @delta
  def initialize
    @delta = "initial"
  end
  def zoom(event)
    @delta = "#{event["delta_x"]}:#{event["delta_y"]}:#{event["delta_z"]}:#{event["delta_mode"]}"
  end

  def html
    %Q{<div onwheel="{zoom($event)}">Wheel target</div><output>{@delta}</output>}
  end
end
