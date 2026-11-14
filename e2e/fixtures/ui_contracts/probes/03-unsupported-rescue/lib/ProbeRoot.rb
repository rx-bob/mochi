class ProbeRoot
  @tag_name = "probe-root"

  def initialize
    begin
      missing
    rescue
      @value = "recovered"
    end
  end

  def html
    %Q{<output>{@value}</output>}
  end
end
