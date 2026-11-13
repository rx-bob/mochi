class CollectionHelper
  def self.transformed_sum(values)
    values.sum(10) do |value|
      value * 2
    end
  end

  def self.reverse_min(values)
    values.min do |left, right|
      right <=> left
    end
  end
end
