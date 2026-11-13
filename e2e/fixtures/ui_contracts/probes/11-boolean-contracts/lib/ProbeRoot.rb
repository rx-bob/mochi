class ProbeRoot
  @tag_name = "probe-root"
  @calls
  @seen
  def initialize
    @calls = 0
    @seen = "none"
  end
  def saved(event)
    @calls += 1
    @seen = event["valid"]
  end
  def html
    %q{<boolean-editor required="false" on:save="{saved($event)}"></boolean-editor><output class="calls">{@calls}</output><output class="seen">{@seen}</output>}
  end
end
