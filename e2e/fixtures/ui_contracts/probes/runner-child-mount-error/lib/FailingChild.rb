class FailingChild
  @tag_name = "failing-child"

  def initialize
    missing_child_mount_method
  end

  def html
    %Q{<p>Mount must fail</p>}
  end
end
