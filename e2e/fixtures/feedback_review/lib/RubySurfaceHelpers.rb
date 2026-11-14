module RubySurfaceHelpers
  def self.integer_type?(value)
    value.is_a?(Integer)
  end

  def self.prepend_one(values, value)
    values.unshift(value)
  end

  def self.prepend_two(values, first, second)
    values.unshift(first, second)
  end
end
