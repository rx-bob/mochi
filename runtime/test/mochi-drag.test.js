const test = require("node:test");
const assert = require("node:assert/strict");

let adapter;
global.MochiHostAdapter = { register(spec) { adapter = spec; } };
require("../mochi-drag.js");

function dataTransfer(types = []) {
  const values = new Map();
  return {
    types,
    dropEffect: "none",
    setData(type, value) { values.set(type, value); this.types = Array.from(values.keys()); },
    getData(type) { return values.get(type) || ""; },
    values,
  };
}

const limits = { payload_bytes: 1024 };

test("typed drag payload keeps nil, false, exact integer tags, and source context", () => {
  const transfer = dataTransfer();
  adapter.sync.set_data({
    event: { type: "dragstart", dataTransfer: transfer },
    source: { tag: "drag-source", id: "source" },
  }, { active: false, empty: null, wide: { __mochi_number: "i64", value: "9223372036854775807" } }, limits);
  const envelope = JSON.parse(transfer.getData(adapter.internalType));
  assert.equal(envelope.version, 1);
  assert.equal(envelope.value.active, false);
  assert.equal(envelope.value.empty, null);
  assert.equal(envelope.value.wide.value, "9223372036854775807");
  assert.deepEqual(envelope.source, { tag: "drag-source", id: "source" });
});

test("text transfers are bounded and available only during native dragstart", () => {
  const transfer = dataTransfer();
  adapter.sync.set_text({ event: { type: "dragstart", dataTransfer: transfer } }, "plain text", limits);
  assert.equal(transfer.getData("text/plain"), "plain text");
  assert.throws(() => adapter.sync.set_text({ event: { type: "drop", dataTransfer: transfer } }, "late", limits), /only valid during dragstart/);
  assert.throws(() => adapter.sync.set_text({ event: { type: "dragstart", dataTransfer: transfer } }, "x".repeat(1025), limits), /byte limit/);
});

test("accepted MIME types prevent browser default and set only supported effects", () => {
  const transfer = dataTransfer(["text/plain"]);
  let prevented = false;
  const event = { type: "dragover", dataTransfer: transfer, preventDefault() { prevented = true; } };
  assert.equal(adapter.sync.accept({ event }, "application/vnd.mochi.value+json", "move"), false);
  assert.equal(prevented, false);
  assert.equal(adapter.sync.accept({ event }, "text/plain", "copy"), true);
  assert.equal(prevented, true);
  assert.equal(transfer.dropEffect, "copy");
  assert.throws(() => adapter.sync.accept({ event }, "text/plain", "all"), /unsupported drop effect/);
});

test("drop snapshots typed data and plain text without exposing DataTransfer", () => {
  const transfer = dataTransfer();
  adapter.sync.set_data({ event: { type: "dragstart", dataTransfer: transfer }, source: { tag: "drag-source" } },
    { ok: true, value: 0 }, limits);
  adapter.sync.set_text({ event: { type: "dragstart", dataTransfer: transfer } }, "visible text", limits);
  transfer.dropEffect = "move";
  const snapshot = adapter.snapshot({ type: "drop", dataTransfer: transfer }, limits);
  assert.deepEqual(snapshot.drag_value, { ok: true, value: 0 });
  assert.equal(snapshot.drag_text, "visible text");
  assert.equal(snapshot.drag_effect, "move");
  assert.deepEqual(snapshot.drag_source, { tag: "drag-source" });
  assert.equal(Object.prototype.hasOwnProperty.call(snapshot, "dataTransfer"), false);
});

test("forged, oversized, and over-nested typed payloads are rejected", () => {
  const malformed = dataTransfer([adapter.internalType]);
  malformed.setData(adapter.internalType, "<img src=x>");
  assert.throws(() => adapter.snapshot({ type: "drop", dataTransfer: malformed }, limits), /malformed/);
  const oversized = dataTransfer(["text/plain"]);
  oversized.setData("text/plain", "x".repeat(1025));
  assert.throws(() => adapter.snapshot({ type: "drop", dataTransfer: oversized }, limits), /byte limit/);
  let nested = null;
  for (let index = 0; index < 34; index += 1) nested = [nested];
  const deep = dataTransfer([adapter.internalType]);
  deep.setData(adapter.internalType, JSON.stringify({ version: 1, value: nested }));
  assert.throws(() => adapter.snapshot({ type: "drop", dataTransfer: deep }, limits), /nesting limit/);
});
