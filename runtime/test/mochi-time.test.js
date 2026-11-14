const { test } = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const time = require("../mochi-time.js");

test("wall clock uses injected integer milliseconds, including pre-epoch", () => {
  let milliseconds = 1794571200123;
  const clock = time.create(() => milliseconds);
  assert.equal(clock.sync.now("[]"), 1794571200123);
  milliseconds = -1250;
  assert.equal(clock.sync.now("[]"), -1250);
  milliseconds = -8640000000000000;
  assert.equal(clock.sync.now("[]"), milliseconds);
  milliseconds = 8640000000000000;
  assert.equal(clock.sync.now("[]"), milliseconds);
});

test("clock rejects unsupported arguments and bad readings, then recovers", () => {
  let reading = 0;
  const clock = time.create(() => reading);
  for (const value of [NaN, Infinity, -Infinity, 0.5, "0", null, 8640000000000001, -8640000000000001]) {
    reading = value;
    assert.throws(() => clock.sync.now("[]"), /integer Unix milliseconds/);
    reading = 42;
    assert.equal(clock.sync.now("[]"), 42);
  }
  for (const args of ["null", "{}", "[1]"]) {
    assert.throws(() => clock.sync.now(args), /takes no arguments/);
  }
  assert.throws(() => clock.sync.now("["), SyntaxError);
});

test("browser adapter registers once and reads wall time without scheduling", () => {
  const registered = [];
  const context = { Date: { now: () => 1234567890123 }, MochiHostAdapter: { register: spec => registered.push(spec) } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../mochi-time.js"), "utf8"), context);
  assert.equal(registered.length, 1);
  assert.equal(registered[0].name, "time");
  assert.equal(registered[0].version, 1);
  assert.equal(registered[0].sync.now("[]"), 1234567890123);
  assert.deepEqual(Object.keys(registered[0].sync), ["now"]);
});
