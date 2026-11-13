# Ruby Array aggregators. The compiler adds this package only for applications
# that call sum, min, or max on a receiver.
class Array
  def sum(initial = 0)
    total = initial
    each do |value|
      total = total + value
    end
    return total
  end

  def min
    return nil if empty?
    result = self[0]
    index = 1
    while index < length
      value = self[index]
      if value < result
        result = value
      end
      index += 1
    end
    return result
  end

  def max
    return nil if empty?
    result = self[0]
    index = 1
    while index < length
      value = self[index]
      if value > result
        result = value
      end
      index += 1
    end
    return result
  end
end
