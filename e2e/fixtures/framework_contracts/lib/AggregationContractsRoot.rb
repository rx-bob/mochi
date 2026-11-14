class AggregationContractsRoot
  @tag_name = "aggregation-contracts-root"
  @event_total

  def initialize
    @event_total = 0
  end

  def total_for(values)
    values.sum
  end

  def doubled_sum(values)
    values.sum { |value| value * 2 }
  end

  def reverse_minimum(values)
    values.min { |left, right| right <=> left }
  end

  def reverse_maximum(values)
    values.max { |left, right| right <=> left }
  end

  def update_total
    @event_total = [4, -2, 3].sum(5)
  end

  def incompatible_minimum
    ["first", 1].min
  end

  def overflowing_sum
    [9_223_372_036_854_775_807, 1].sum
  end

  def html
    %Q{
      <span class="sum">{total_for([1, 2, 3])}</span>
      <span class="empty-sum">{[].sum}</span>
      <span class="initial-sum">{[-2, 3].sum(10)}</span>
      <span class="mixed-sum">{[1, 2.5, -0.5].sum}</span>
      <span class="block-sum">{doubled_sum([1, 2, 3])}</span>
      <span class="minimum">{[3, -4, 1].min}</span>
      <span class="maximum">{[3, -4, 1].max}</span>
      <span class="empty-minimum">{[].min}</span>
      <span class="empty-maximum">{[].max}</span>
      <span class="block-minimum">{reverse_minimum([3, -4, 1])}</span>
      <span class="block-maximum">{reverse_maximum([3, -4, 1])}</span>
      <span class="string-minimum">{["pear", "apple", "plum"].min}</span>
      <span class="string-maximum">{["pear", "apple", "plum"].max}</span>
      <span class="event-total">{@event_total}</span>
      <button class="update" onclick="{update_total}">Update</button>
      <button class="incompatible" onclick="{incompatible_minimum}">Incompatible values</button>
      <button class="overflow" onclick="{overflowing_sum}">Overflow</button>
    }
  end
end
