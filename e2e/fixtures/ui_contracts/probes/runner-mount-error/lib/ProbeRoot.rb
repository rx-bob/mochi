# Deliberately invalid fixture for the test runner's rejected-mount contract.
# It must not depend on a framework feature that a later story repairs.
class ProbeRoot
  @tag_name = "probe-root"

  def initialize
    missing_mount_method
  end

  def html
    %Q{<p>Mount must fail</p>}
  end
end
