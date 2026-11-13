// mochi-format.js - optional browser Intl adapter for MochiFormat.
//
// The loader installs the capability registrar before requesting this script.
// The VM then calls the registered synchronous `format` operation through the
// small host-dispatch bridge in mochi-gvm. It is a separate script so
// applications that never use MochiFormat do not request it.
(function (global) {
  "use strict";

  var MAX_CACHED_FORMATTERS = 32;
  // Above this many minor units, dividing by the scale can lose the last cent
  // when the value becomes a JavaScript Number. Report it instead of rounding.
  var MAX_EXACT_CURRENCY_MINOR = 1000000000000000;

  var numberCache = new Map();
  var dateCache = new Map();

  var NUMBER_OPTIONS = {
    style: "style",
    currency: "currency",
    currency_display: "currencyDisplay",
    currency_sign: "currencySign",
    notation: "notation",
    compact_display: "compactDisplay",
    unit: "unit",
    unit_display: "unitDisplay",
    minimum_integer_digits: "minimumIntegerDigits",
    minimum_fraction_digits: "minimumFractionDigits",
    maximum_fraction_digits: "maximumFractionDigits",
    minimum_significant_digits: "minimumSignificantDigits",
    maximum_significant_digits: "maximumSignificantDigits",
    use_grouping: "useGrouping",
    sign_display: "signDisplay",
    rounding_mode: "roundingMode",
    rounding_priority: "roundingPriority",
    trailing_zero_display: "trailingZeroDisplay",
    numbering_system: "numberingSystem",
    locale_matcher: "localeMatcher"
  };

  var DATE_OPTIONS = {
    date_style: "dateStyle",
    time_style: "timeStyle",
    calendar: "calendar",
    numbering_system: "numberingSystem",
    hour12: "hour12",
    hour_cycle: "hourCycle",
    era: "era",
    year: "year",
    month: "month",
    day: "day",
    weekday: "weekday",
    day_period: "dayPeriod",
    hour: "hour",
    minute: "minute",
    second: "second",
    fractional_second_digits: "fractionalSecondDigits",
    time_zone_name: "timeZoneName",
    format_matcher: "formatMatcher",
    locale_matcher: "localeMatcher"
  };

  function fail(message) {
    throw new Error("format: " + message);
  }

  function decodeValue(raw) {
    if (raw && typeof raw === "object" && raw.__mochi_number) {
      if (raw.__mochi_number === "i64") {
        if (typeof BigInt !== "function") fail("the browser does not support exact 64-bit integers");
        return BigInt(raw.value);
      }
      if (raw.__mochi_number === "f64") return Number(raw.value);
    }
    return raw;
  }

  function readOptions(raw) {
    if (raw === null || raw === undefined) return {};
    if (typeof raw !== "object" || Array.isArray(raw)) fail("options must be a Hash");
    return raw;
  }

  function readLocale(options) {
    var locale = options.locale === undefined ? "en-US" : options.locale;
    if (typeof locale !== "string" || locale.length === 0) {
      fail("locale must be a non-empty String");
    }
    try {
      Intl.getCanonicalLocales(locale);
    } catch (error) {
      fail("invalid locale '" + locale + "': " + (error.message || error));
    }
    return locale;
  }

  function intlOptions(options, mapping, kind) {
    var result = {};
    var keys = Object.keys(options);
    for (var index = 0; index < keys.length; index++) {
      var key = keys[index];
      if (key === "locale" || key === "scale") continue;
      if (kind === "date" && (key === "timezone" || key === "time_zone")) continue;
      var mapped = mapping[key];
      if (!mapped) fail("unsupported " + kind + " option '" + key + "'");
      result[mapped] = options[key];
    }
    return result;
  }

  function cacheKey(locale, options) {
    var keys = Object.keys(options).sort();
    var parts = [locale];
    for (var index = 0; index < keys.length; index++) {
      parts.push(keys[index] + "=" + String(options[keys[index]]));
    }
    return parts.join("\u0000");
  }

  function cached(cache, key, create, maxEntries) {
    var formatter = cache.get(key);
    if (formatter) return formatter;
    formatter = create();
    var capacity = Number.isSafeInteger(maxEntries) && maxEntries > 0
      ? maxEntries
      : MAX_CACHED_FORMATTERS;
    if (cache.size >= capacity) cache.clear();
    cache.set(key, formatter);
    return formatter;
  }

  function createNumberFormatter(locale, options) {
    try {
      return new Intl.NumberFormat(locale, options);
    } catch (error) {
      fail("invalid number options for locale '" + locale + "': " + (error.message || error));
    }
  }

  function createDateFormatter(locale, options) {
    try {
      return new Intl.DateTimeFormat(locale, options);
    } catch (error) {
      fail("invalid date options for locale '" + locale + "': " + (error.message || error));
    }
  }

  function currencyNumber(rawValue, scale) {
    if (rawValue && typeof rawValue === "object" && rawValue.__mochi_number === "f64") {
      fail("currency amount must be an Integer number of minor units");
    }
    var value = decodeValue(rawValue);
    if (typeof value === "bigint") {
      if (value < BigInt(-MAX_EXACT_CURRENCY_MINOR) ||
          value > BigInt(MAX_EXACT_CURRENCY_MINOR)) {
        fail("currency amount exceeds exact formatting range");
      }
      value = Number(value);
    } else if (typeof value === "number") {
      if (!Number.isSafeInteger(value)) {
        fail("currency amount must be an Integer number of minor units");
      }
    } else {
      fail("currency amount must be an Integer number of minor units");
    }
    if (Math.abs(value) > MAX_EXACT_CURRENCY_MINOR) {
      fail("currency amount exceeds exact formatting range");
    }
    if (!Number.isInteger(scale) || scale < 0 || scale > 20) {
      fail("currency scale must be an integer from 0 to 20");
    }
    return value / Math.pow(10, scale);
  }

  function formatNumber(rawValue, rawOptions, cacheCapacity) {
    var options = readOptions(rawOptions);
    var locale = readLocale(options);
    var value = decodeValue(rawValue);
    var style = options.style === undefined ? "decimal" : options.style;

    if (style !== "currency" && options.scale !== undefined) {
      fail("scale is only supported for currency formatting");
    }
    if (style === "currency") {
      value = currencyNumber(rawValue, options.scale === undefined ? 2 : options.scale);
    } else if (typeof value !== "number" && typeof value !== "bigint") {
      fail("number value must be a Number or Integer");
    }

    var intl = intlOptions(options, NUMBER_OPTIONS, "number");
    if (style === "compact") {
      style = "decimal";
      if (intl.notation === undefined) intl.notation = "compact";
    }
    if (intl.style === undefined) intl.style = style;
    if (intl.style === "currency" && intl.currency === undefined) intl.currency = "USD";

    var key = cacheKey(locale, intl);
    var formatter = cached(numberCache, key, function () {
      return createNumberFormatter(locale, intl);
    }, cacheCapacity);
    try {
      return formatter.format(value);
    } catch (error) {
      fail("failed to format number: " + (error.message || error));
    }
  }

  function parseDate(text, options) {
    if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
      var timezone = options.time_zone === undefined ? options.timezone : options.time_zone;
      if (timezone !== undefined && timezone !== "UTC") {
        fail("date-only values are calendar dates; pass a full ISO timestamp to use a timezone");
      }
      var parts = text.split("-");
      var date = new Date(Date.UTC(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])));
      if (isNaN(date.getTime())) fail("invalid ISO date '" + text + "'");
      return date;
    }
    var parsed = new Date(text);
    if (isNaN(parsed.getTime())) fail("invalid ISO date '" + text + "'");
    return parsed;
  }

  function formatDate(rawValue, rawOptions, cacheCapacity) {
    var options = readOptions(rawOptions);
    var locale = readLocale(options);
    var text = String(rawValue);
    var date = parseDate(text, options);
    var intl = intlOptions(options, DATE_OPTIONS, "date");

    var timezone = options.time_zone === undefined ? options.timezone : options.time_zone;
    if (timezone !== undefined) {
      if (typeof timezone !== "string" || timezone.length === 0) {
        fail("timezone must be a non-empty String");
      }
      intl.timeZone = timezone;
    } else {
      intl.timeZone = "UTC";
    }
    if (intl.dateStyle === undefined && intl.year === undefined &&
        intl.month === undefined && intl.day === undefined &&
        intl.weekday === undefined && intl.timeStyle === undefined &&
        intl.hour === undefined && intl.minute === undefined &&
        intl.second === undefined && intl.fractionalSecondDigits === undefined &&
        intl.timeZoneName === undefined && intl.dayPeriod === undefined) {
      intl.dateStyle = "medium";
    }

    var key = cacheKey(locale, intl);
    var formatter = cached(dateCache, key, function () {
      return createDateFormatter(locale, intl);
    }, cacheCapacity);
    try {
      return formatter.format(date);
    } catch (error) {
      fail("failed to format date: " + (error.message || error));
    }
  }

  function format(kind, valueJson, optionsJson) {
    var value;
    var options;
    try {
      value = JSON.parse(valueJson);
      options = optionsJson && optionsJson !== "null" ? JSON.parse(optionsJson) : {};
    } catch (error) {
      fail("invalid formatting request: " + (error.message || error));
    }
    if (kind === "number") return formatNumber(value, options);
    if (kind === "date") return formatDate(value, options);
    fail("unsupported formatting kind '" + kind + "'");
  }

  // Host capability contract: one JSON argument array, one typed JSON result.
  function formatArgs(argsJson, limits) {
    var args;
    try {
      args = JSON.parse(argsJson);
    } catch (error) {
      fail("invalid formatting arguments: " + (error.message || error));
    }
    if (!Array.isArray(args) || args.length < 2) {
      fail("formatting requires kind and value arguments");
    }
    var kind = args[0];
    var value = args[1];
    var options = args[2] && typeof args[2] === "object" ? args[2] : {};
    var cacheCapacity = limits && limits.cache_entries;
    if (!Number.isSafeInteger(cacheCapacity) || cacheCapacity <= 0) {
      fail("formatting capability has no valid cache capacity");
    }
    if (kind === "number") return formatNumber(value, options, cacheCapacity);
    if (kind === "date") return formatDate(value, options, cacheCapacity);
    fail("unsupported formatting kind '" + String(kind) + "'");
  }

  function debugStats() {
    return {
      numberFormatters: numberCache.size,
      dateFormatters: dateCache.size
    };
  }

  var host = {
    name: "formatting",
    version: 1,
    sync: {
      format: formatArgs
    },
    format: format,
    debugStats: debugStats
  };
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) module.exports = host;
})(typeof globalThis !== "undefined" ? globalThis : window);
