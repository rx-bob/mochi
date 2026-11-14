
class ProbeRoot
  @tag_name = "probe-root"
  prop :enabled, Boolean, default: false

  def html
    %Q{<output>{@enabled}</output>}
  end
end
