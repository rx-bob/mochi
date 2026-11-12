# Optional number and date formatting backed by the browser's Intl support.
#
# MochiFormat is ordinary Ruby bytecode. The compiler emits it only when an
# application mentions the class. The browser-facing formatting host is
# requested only for those applications, before their components initialize.
class MochiFormat

  # Grouped decimal formatting. The locale defaults to en-US.
  def self.number(value, locale = "en-US", options = {})
    return Mochi.format_number(value, MochiFormat.options(locale, options, "decimal", nil, nil, nil))
  end

  def self.decimal(value, locale = "en-US", options = {})
    return Mochi.format_number(value, MochiFormat.options(locale, options, "decimal", nil, nil, nil))
  end

  # Formats an integer number of minor units, for example cents.
  def self.currency(minor_units, currency = "USD", locale = "en-US", scale = 2, options = {})
    return Mochi.format_number(minor_units, MochiFormat.options(locale, options, "currency", currency, scale, nil))
  end

  # Compact notation such as 1.2M.
  def self.compact(value, locale = "en-US", options = {})
    return Mochi.format_number(value, MochiFormat.options(locale, options, "compact", nil, nil, nil))
  end

  # Formats a ratio, so 0.42 becomes 42%.
  def self.percent(value, locale = "en-US", options = {})
    return Mochi.format_number(value, MochiFormat.options(locale, options, "percent", nil, nil, nil))
  end

  # Formats an ISO date or timestamp. Date-only values are calendar dates and
  # use UTC; a full timestamp honors the timezone.
  def self.date(iso, locale = "en-US", timezone = "UTC", options = {})
    result = MochiFormat.options(locale, options, nil, nil, nil, timezone)
    if !result.key?("date_style") && !result.key?("year") && !result.key?("month") && !result.key?("day") && !result.key?("weekday") && !result.key?("time_style") && !result.key?("hour") && !result.key?("minute") && !result.key?("second") && !result.key?("fractional_second_digits") && !result.key?("time_zone_name") && !result.key?("day_period")
      result["date_style"] = "medium"
    end
    return Mochi.format_date(iso, result)
  end

  def self.options(locale, options, style, currency, scale, timezone)
    result = {}
    result["locale"] = locale
    if style == "compact"
      result["style"] = "decimal"
      result["notation"] = "compact"
    elsif style != nil
      result["style"] = style
    end
    if currency != nil
      result["currency"] = currency
    end
    if scale != nil
      result["scale"] = scale
      if style == "currency"
        result["minimum_fraction_digits"] = scale
        result["maximum_fraction_digits"] = scale
      end
    end
    if timezone != nil
      result["timezone"] = timezone
    end
    if options != nil
      options.keys.each do |key|
        result[key.to_s] = options[key]
      end
    end
    return result
  end
end
