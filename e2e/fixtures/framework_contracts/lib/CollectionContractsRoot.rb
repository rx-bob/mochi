class CollectionContractsRoot
  @tag_name = "collection-contracts-root"
  @values
  @initial_sum
  @event_value

  def initialize
    @values = [1, 2, 3]
    @initial_sum = @values.sum
    @event_value = 0
  end

  def binding_minimum
    @values.min
  end

  def binding_maximum
    @values.max
  end

  def update_value
    @event_value = @values.max do |left, right|
      right <=> left
    end
  end

  def html
    %Q{
      <span class="sum">{@initial_sum}</span>
      <span class="minimum">{binding_minimum}</span>
      <span class="maximum">{binding_maximum}</span>
      <span class="empty-minimum">{[].min}</span>
      <span class="empty-maximum">{[].max}</span>
      <span class="helper-sum">{CollectionHelper.transformed_sum(@values)}</span>
      <span class="helper-min">{CollectionHelper.reverse_min(@values)}</span>
      <span class="event-value">{@event_value}</span>
      <button class="update" onclick="{update_value}">Update</button>
    }
  end
end
