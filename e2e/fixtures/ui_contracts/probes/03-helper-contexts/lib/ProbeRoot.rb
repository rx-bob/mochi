class ProbeRoot
  @tag_name = "probe-root"
  @initial
  @event
  @built

  def initialize
    @initial = "#{RecordData::BASE}:#{RecordData.base_ms}"
    @built = RecordData.build
    @event = "not called"
  end

  def helper_value
    "#{RecordData::BASE}:#{RecordData.base_ms}"
  end

  def update
    @event = "#{RecordData::BASE}:#{RecordData.base_ms}:#{RecordData.build}"
  end

  def missing_constant
    RecordData::MISSING
  end

  def missing_method
    RecordData.missing
  end

  def html
    %Q{
      <output class="initial">{@initial}</output>
      <output class="method">{helper_value}</output>
      <output class="template">{RecordData::BASE}:{RecordData.base_ms}</output>
      <output class="other">{OtherData::BASE}:{OtherData.base_ms}</output>
      <output class="built">{@built}</output>
      <output class="template-built">{RecordData.build}</output>
      <output class="event">{@event}</output>
      <button class="update" onclick="{update}">Update</button>
      <button class="missing-constant" onclick="{missing_constant}">Missing constant</button>
      <button class="missing-method" onclick="{missing_method}">Missing method</button>
    }
  end
end
