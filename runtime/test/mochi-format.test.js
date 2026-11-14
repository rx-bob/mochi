const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const HOST_PATH = path.join(__dirname, "..", "mochi-format.js");

function host() {
  delete require.cache[require.resolve(HOST_PATH)];
  return require(HOST_PATH);
}

function number(value, options) {
  return host().format("number", JSON.stringify(value),
    options === undefined ? undefined : JSON.stringify(options));
}

function date(value, options) {
  return host().format("date", JSON.stringify(value),
    options === undefined ? undefined : JSON.stringify(options));
}

function exact(kind, value) {
  return JSON.stringify({ __mochi_number: kind, value: String(value) });
}

test("Unix-second timestamps format deterministic instants in explicit zones", () => {
  const options = { locale: "en-GB", timezone: "UTC", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour_cycle: "h23", fractional_second_digits: 3 };
  const format = (value, zone = "UTC") => host().format("timestamp", value, JSON.stringify({ ...options, timezone: zone }));
  assert.equal(format(exact("f64", "1794571200.123")), "13/11/2026, 12:00:00.123");
  assert.equal(format(exact("f64", "1794571200.123"), "Asia/Tokyo"), "13/11/2026, 21:00:00.123");
  assert.equal(format(exact("f64", "-1.25")), "31/12/1969, 23:59:58.750");
  assert.equal(format(exact("i64", "1")), "01/01/1970, 00:00:01.000");
  assert.equal(format("0"), "01/01/1970, 00:00:00.000");
  assert.equal(format("0.0001"), "01/01/1970, 00:00:00.000");
  assert.equal(format("-0.0001"), "01/01/1970, 00:00:00.000");
  assert.equal(format("1000"), "01/01/1970, 00:16:40.000");
});

test("timestamp validation rejects nonnumeric, nonfinite, and out-of-range input", () => {
  const adapter = host();
  const options = JSON.stringify({ locale: "en-GB", timezone: "UTC" });
  for (const value of ['"0"', "true", "null", "{}", exact("f64", "NaN"), exact("f64", "Infinity")]) {
    assert.throws(() => adapter.format("timestamp", value, options), /finite Integer or Float Unix seconds/);
  }
  for (const value of ["8640000000001", "-8640000000001", exact("i64", "9223372036854775807")]) {
    assert.throws(() => adapter.format("timestamp", value, options), /seconds exceed supported range/);
  }
  for (const value of ["8640000000000", "-8640000000000"]) {
    assert.equal(typeof adapter.format("timestamp", value, options), "string");
  }
  assert.throws(() => adapter.format("timestamp", "0", '{"timezone":"bad/zone"}'), /invalid date options/);
  assert.equal(adapter.sync.format('["timestamp",0,{"locale":"en-GB","timezone":"UTC"}]', {cache_entries:32}), "1 Jan 1970");
});

test("number formatting uses explicit locales and deterministic defaults", () => {
  assert.equal(number(1234567.89, {
    maximum_fraction_digits: 2,
  }), "1,234,567.89");
  assert.equal(number(1234.5, {
    locale: "de-DE",
  }), "1.234,5");
  assert.equal(number(1234.5), "1,234.5");
  assert.equal(number(-1234.5, {
    locale: "en-US",
  }), "-1,234.5");
  assert.equal(number(1234567, {
    notation: "compact",
  }), "1.2M");
  assert.equal(number(0.42, {
    style: "percent",
  }), "42%");
});

test("currency formatting accepts exact minor units and validates the scale", () => {
  assert.equal(number(123456, {
    style: "currency",
    currency: "USD",
    scale: 2,
  }), "$1,234.56");
  assert.equal(number(-123456, {
    style: "currency",
    currency: "USD",
    scale: 2,
  }), "-$1,234.56");
  assert.equal(host().format("number", exact("i64", "1000000000000000"), JSON.stringify({
    style: "currency",
    currency: "USD",
    scale: 2,
  })), "$10,000,000,000,000.00");
  assert.equal(host().format("number", exact("i64", "-1000000000000000"), JSON.stringify({
    style: "currency",
    currency: "USD",
    scale: 2,
  })), "-$10,000,000,000,000.00");

  assert.throws(
    () => number(1000000000000001, {
      style: "currency",
      currency: "USD",
      scale: 2,
    }),
    /currency amount exceeds exact formatting range/,
  );
  assert.throws(
    () => host().format("number", exact("i64", "-1000000000000001"), JSON.stringify({
      style: "currency",
      currency: "USD",
      scale: 2,
    })),
    /currency amount exceeds exact formatting range/,
  );
  assert.throws(
    () => number(1.5, { style: "currency", currency: "USD", scale: 2 }),
    /currency amount must be an Integer number of minor units/,
  );
  assert.throws(
    () => host().format("number", exact("f64", "1"), JSON.stringify({
      style: "currency",
      currency: "USD",
      scale: 2,
    })),
    /currency amount must be an Integer number of minor units/,
  );
  assert.throws(
    () => number("9.61", { style: "currency", currency: "USD", scale: 2 }),
    /currency amount must be an Integer number of minor units/,
  );
  assert.throws(
    () => number(100, { style: "currency", currency: "USD", scale: "2" }),
    /currency scale must be an integer from 0 to 20/,
  );
  assert.equal(number(1, {
    style: "currency",
    currency: "USD",
    scale: 0,
    minimum_fraction_digits: 0,
    maximum_fraction_digits: 0,
  }), "$1");
  assert.equal(number(1, {
    style: "currency",
    currency: "USD",
    scale: 20,
    minimum_fraction_digits: 20,
    maximum_fraction_digits: 20,
  }), "$0.00000000000000000001");
  assert.throws(
    () => number(100, { scale: 2 }),
    /scale is only supported for currency formatting/,
  );
});

test("64-bit integers stay exact through the host boundary", () => {
  assert.equal(host().format("number",
    exact("i64", "9007199254740993"),
    JSON.stringify({})), "9,007,199,254,740,993");
  assert.equal(host().format("number",
    exact("i64", "9223372036854775807"),
    JSON.stringify({})), "9,223,372,036,854,775,807");
  assert.equal(host().format("number",
    exact("f64", "1234.5"),
    JSON.stringify({})), "1,234.5");
});

test("date formatting honors the timezone and rejects a date-only timezone", () => {
  assert.equal(date("2026-10-11", {
    month: "short",
    day: "numeric",
  }), "Oct 11");
  assert.equal(date("2026-11-09T23:30:00Z", {
    date_style: "medium",
    time_style: "short",
  }), "Nov 9, 2026, 11:30 PM");
  assert.equal(date("2026-11-09T23:30:00Z", {
    timezone: "Asia/Tokyo",
    date_style: "medium",
    time_style: "short",
  }), "Nov 10, 2026, 8:30 AM");
  assert.equal(date("2026-11-09T23:30:00Z", {
    hour: "numeric",
    minute: "numeric",
  }), "11:30 PM");
  assert.throws(
    () => date("2026-10-11", { timezone: "Asia/Tokyo" }),
    /date-only values are calendar dates/,
  );
});

test("invalid locales and options report actionable errors", () => {
  assert.throws(
    () => number(1, { locale: "en_US" }),
    /invalid locale 'en_US'/,
  );
  assert.throws(
    () => number(1, { bogus: true }),
    /unsupported number option 'bogus'/,
  );
  assert.throws(
    () => date("2026-10-11", { bogus: true }),
    /unsupported date option 'bogus'/,
  );
  assert.throws(
    () => host().format("number", "1", "[]"),
    /options must be a Hash/,
  );
  assert.throws(
    () => host().format("bogus", "1", "{}"),
    /unsupported formatting kind 'bogus'/,
  );
});

test("formatter caches are bounded and reused", () => {
  const adapter = host();
  const first = adapter.format("number", "1", JSON.stringify({
    minimum_integer_digits: 2,
  }));
  assert.equal(adapter.debugStats().numberFormatters, 1);
  assert.equal(adapter.format("number", "1", JSON.stringify({
    minimum_integer_digits: 2,
  })), first);
  assert.equal(adapter.debugStats().numberFormatters, 1);

  for (let index = 0; index < 40; index += 1) {
    adapter.format("number", "1", JSON.stringify({
      minimum_integer_digits: (index % 21) + 1,
    }));
  }
  assert.ok(adapter.debugStats().numberFormatters <= 32);

  for (let index = 0; index < 40; index += 1) {
    adapter.format("date", JSON.stringify("2026-11-09T23:30:00Z"), JSON.stringify({
      hour: "numeric",
      minute: "numeric",
      time_zone: [
        "UTC", "America/New_York", "Asia/Tokyo", "Europe/London",
        "Australia/Sydney", "America/Los_Angeles", "Europe/Paris",
        "America/Chicago", "Asia/Kolkata", "Pacific/Auckland",
        "America/Sao_Paulo", "Africa/Cairo", "Asia/Dubai", "Asia/Shanghai",
        "Europe/Berlin", "Europe/Madrid", "Europe/Rome", "Europe/Moscow",
        "America/Toronto", "America/Vancouver", "America/Mexico_City",
        "America/Denver", "America/Phoenix", "America/Anchorage",
        "Pacific/Honolulu", "Asia/Singapore", "Asia/Hong_Kong",
        "Asia/Seoul", "Asia/Bangkok", "Asia/Jakarta", "Asia/Karachi",
        "Europe/Stockholm", "Europe/Warsaw", "Europe/Athens",
        "Africa/Johannesburg", "America/Argentina/Buenos_Aires",
        "Pacific/Fiji", "Atlantic/Reykjavik", "Asia/Tehran", "Asia/Jerusalem",
      ][index],
    }));
  }
  assert.ok(adapter.debugStats().dateFormatters <= 32);
});

test("host formatting operation uses its immutable profile cache limit", () => {
  const adapter = host();
  const limits = Object.freeze({ cache_entries: 1 });
  adapter.sync.format(JSON.stringify(["number", 1, { minimum_integer_digits: 1 }]), limits);
  adapter.sync.format(JSON.stringify(["number", 1, { minimum_integer_digits: 2 }]), limits);
  assert.equal(adapter.debugStats().numberFormatters, 1);
  assert.throws(
    () => adapter.sync.format(JSON.stringify(["number", 1, {}]), {}),
    /no valid cache capacity/,
  );
});
