# Exact rational amounts of minor units, for example cents.
#
# A ledger is an ordinary Hash with :numerator and :denominator entries. Add
# at the scale the caller needs, keep every intermediate value exact, and round
# only at the display boundary with one of the named round_* methods.
#
# The helper does no currency symbols, grouping, locale lookup, or decimal
# formatting. A denominator of zero reports the VM's division-by-zero error,
# and a cross-product or scale that leaves the signed 64-bit range reports
# integer overflow.
class MochiMoney

  # A new zero ledger.
  def self.ledger
    return {:numerator => 0, :denominator => 1}
  end

  # The VM exposes integer-only even?/odd? dispatch but does not yet expose
  # Integer#=== or Kernel#raise. Calling an integer-only method here rejects
  # floats and other values before they can enter or mutate a ledger.
  def self.__require_integer(value)
    value.even?
    return value
  end

  # A ledger holding numerator / denominator minor units.
  def self.amount(numerator, denominator)
    value = MochiMoney.ledger
    return MochiMoney.add_ratio(value, numerator, denominator)
  end

  # A ledger holding a whole number of minor units.
  def self.minor(amount)
    return MochiMoney.amount(amount, 1)
  end

  # Greatest common divisor for normalization. Ruby's floor remainder keeps
  # the minimum signed 64-bit integer exact without negating it.
  def self.gcd(a, b)
    MochiMoney.__require_integer(a)
    MochiMoney.__require_integer(b)
    while b != 0
      remainder = a % b
      a = b
      b = remainder
    end
    return a
  end

  def self.normalize(value)
    numerator = value[:numerator]
    denominator = value[:denominator]
    MochiMoney.__require_integer(numerator)
    MochiMoney.__require_integer(denominator)
    if denominator == 0
      numerator = numerator / denominator
    end
    if denominator < 0
      numerator = -numerator
      denominator = -denominator
    end
    divisor = MochiMoney.gcd(numerator, denominator)
    normalized_numerator = numerator / divisor
    normalized_denominator = denominator / divisor
    value[:numerator] = normalized_numerator
    value[:denominator] = normalized_denominator
    return value
  end

  # Adds an exact numerator / denominator amount to a ledger.
  def self.add_ratio(value, numerator, denominator)
    MochiMoney.__require_integer(value[:numerator])
    MochiMoney.__require_integer(value[:denominator])
    MochiMoney.__require_integer(numerator)
    MochiMoney.__require_integer(denominator)
    if denominator == 0
      numerator = numerator / denominator
    end
    total_numerator = value[:numerator] * denominator + numerator * value[:denominator]
    total_denominator = value[:denominator] * denominator
    candidate = MochiMoney.normalize({:numerator => total_numerator, :denominator => total_denominator})
    value[:numerator] = candidate[:numerator]
    value[:denominator] = candidate[:denominator]
    return value
  end

  # Adds a whole number of minor units to a ledger.
  def self.add_minor(value, amount)
    return MochiMoney.add_ratio(value, amount, 1)
  end

  # Adds another ledger to a ledger exactly.
  def self.merge(value, other)
    return MochiMoney.add_ratio(value, other[:numerator], other[:denominator])
  end

  # Multiplies a ledger by numerator / denominator exactly.
  def self.apply_ratio(value, numerator, denominator)
    MochiMoney.__require_integer(value[:numerator])
    MochiMoney.__require_integer(value[:denominator])
    MochiMoney.__require_integer(numerator)
    MochiMoney.__require_integer(denominator)
    if denominator == 0
      numerator = numerator / denominator
    end
    total_numerator = value[:numerator] * numerator
    total_denominator = value[:denominator] * denominator
    candidate = MochiMoney.normalize({:numerator => total_numerator, :denominator => total_denominator})
    value[:numerator] = candidate[:numerator]
    value[:denominator] = candidate[:denominator]
    return value
  end

  def self.numerator(value)
    MochiMoney.__require_integer(value[:numerator])
    return value[:numerator]
  end

  def self.denominator(value)
    MochiMoney.__require_integer(value[:denominator])
    return value[:denominator]
  end

  # Reduced exact value, for example "303/5".
  def self.exact(value)
    MochiMoney.__require_integer(value[:numerator])
    MochiMoney.__require_integer(value[:denominator])
    return value[:numerator].to_s + "/" + value[:denominator].to_s
  end

  # Internal shared rounding routine. Use the named round_* methods.
  def self.round_with(value, mode)
    numerator = value[:numerator]
    denominator = value[:denominator]
    MochiMoney.__require_integer(numerator)
    MochiMoney.__require_integer(denominator)
    quotient = numerator / denominator
    remainder = numerator % denominator
    if remainder == 0
      return quotient
    end
    if mode == "floor"
      return quotient
    elsif mode == "ceil"
      return quotient + 1
    elsif mode == "truncate"
      if numerator < 0
        return quotient + 1
      end
      return quotient
    end
    threshold = denominator - remainder
    if remainder < threshold
      return quotient
    elsif remainder > threshold
      return quotient + 1
    end
    if mode == "half_up"
      if numerator < 0
        return quotient
      end
      return quotient + 1
    elsif mode == "half_down"
      if numerator < 0
        return quotient + 1
      end
      return quotient
    elsif mode == "half_even"
      if quotient % 2 == 0
        return quotient
      end
      return quotient + 1
    end
    return quotient
  end

  # Nearest; exact halves away from zero. Matches Intl.NumberFormat's default
  # currency rounding.
  def self.round_half_up(value)
    return MochiMoney.round_with(value, "half_up")
  end

  # Nearest; exact halves toward zero.
  def self.round_half_down(value)
    return MochiMoney.round_with(value, "half_down")
  end

  # Nearest; exact halves to the even integer.
  def self.round_half_even(value)
    return MochiMoney.round_with(value, "half_even")
  end

  # Toward negative infinity.
  def self.round_floor(value)
    return MochiMoney.round_with(value, "floor")
  end

  # Toward positive infinity.
  def self.round_ceil(value)
    return MochiMoney.round_with(value, "ceil")
  end

  # Toward zero.
  def self.round_truncate(value)
    return MochiMoney.round_with(value, "truncate")
  end
end
