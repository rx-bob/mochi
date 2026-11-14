class ReviewChild
  @tag_name = "review-child"
  prop :label, String, required: true
  prop :meta, Hash, default: {}
  event :action, value: String
  event :change, value: String
  def action
    emit("action", {"value" => @label})
  end
  def change
    emit("change", {"value" => @meta["value"]})
  end
  def html
    %Q{<div><span class="label">{@label}</span><button class="action" onclick="{action}"><span>Action</span></button><button class="change" onclick="{change}">Change</button></div>}
  end
end
