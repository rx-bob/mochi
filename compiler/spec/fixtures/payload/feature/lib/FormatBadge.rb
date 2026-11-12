class FormatBadge
  @tag_name = "format-badge"
  @label

  def initialize
    @label = MochiFormat.decimal(1234.5, "en-US")
  end

  def html
    %Q{<span>{@label}</span>}
  end
end
