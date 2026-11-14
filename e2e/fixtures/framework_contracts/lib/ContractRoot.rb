class ContractChild
  @tag_name = "contract-child"
  prop :label, String, default: "unset"

  def html
    %Q{<span class="child-label">{@label}</span>}
  end
end

class ContractRoot
  @tag_name = "contract-root"
  @label

  def initialize
    @label = "before"
  end

  def html
    %Q{
      <button class="change" onclick="{change}">Change</button>
      <contract-child label="{@label}"></contract-child>
    }
  end

  def change
    @label = "after"
  end
end
