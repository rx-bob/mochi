class ChildProbe
  @tag_name = "child-probe"
  prop :label, String, default: ""
  prop :remaining, Integer, default: 0
  prop :reset, String, default: ""
  prop :tone, String, default: "normal"

  def html
    %Q{<div class="probe" data-label="{@label}" data-reset="{@reset}" data-tone="{@tone}">{@remaining}%</div>}
  end
end
