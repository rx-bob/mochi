const test = require("node:test");
const assert = require("node:assert/strict");

let adapter;
global.MochiHostAdapter = {
  register(spec) { adapter = spec; },
};
require("../mochi-pointer.js");

function target() {
  const listeners = new Map();
  const captures = new Set();
  return {
    nodeType: 1,
    isConnected: true,
    listeners,
    addEventListener(name, callback) {
      const list = listeners.get(name) || [];
      list.push(callback);
      listeners.set(name, list);
    },
    removeEventListener(name, callback) {
      listeners.set(name, (listeners.get(name) || []).filter((listener) => listener !== callback));
    },
    setPointerCapture(pointerId) { captures.add(pointerId); },
    hasPointerCapture(pointerId) { return captures.has(pointerId); },
    releasePointerCapture(pointerId) { captures.delete(pointerId); },
    lose(pointerId) {
      captures.delete(pointerId);
      for (const callback of listeners.get("lostpointercapture") || []) callback({ pointerId });
    },
  };
}

test("pointer adapter captures distinct live pointers and releases by owner", () => {
  const first = target();
  const second = target();
  const event = { pointerId: 7, buttons: 1 };
  assert.equal(adapter.sync.capture(first, 7, "owner-a", 1, event), true);
  assert.equal(adapter.sync.capture(second, 9, "owner-a", 1, { pointerId: 9, buttons: 1 }), true);
  assert.equal(adapter.debugCaptureCount(), 2);
  assert.throws(() => adapter.sync.release(7, "owner-b", 1), /no live capture owned by this component/);
  assert.equal(adapter.sync.release(7, "owner-a", 1, first), true);
  assert.equal(first.hasPointerCapture(7), false);
  assert.equal(adapter.debugCaptureCount(), 1);
});

test("pointer adapter rejects inactive, stale, reused, and foreign targets", () => {
  const connected = target();
  assert.throws(() => adapter.sync.capture(connected, 2, "owner-a", 1, null), /active pointer event/);
  assert.throws(() => adapter.sync.capture(connected, 2, "owner-a", 1,
    { pointerId: 2, buttons: 0 }), /active pointer event/);
  connected.isConnected = false;
  assert.throws(() => adapter.sync.capture(connected, 2, "owner-a", 1,
    { pointerId: 2, buttons: 1 }), /stale or disconnected/);
  connected.isConnected = true;
  adapter.sync.capture(connected, 2, "owner-a", 1, { pointerId: 2, buttons: 1 });
  assert.throws(() => adapter.sync.capture(target(), 2, "owner-b", 2,
    { pointerId: 2, buttons: 1 }), /another live component/);
  adapter.disposeOwner("owner-a", 1);
  assert.equal(connected.hasPointerCapture(2), false);
  assert.equal(adapter.debugCaptureCount(), 0);
});

test("explicit release still succeeds after native lost capture in the same dispatch turn", () => {
  const element = target();
  adapter.sync.capture(element, 12, "owner", 4, { pointerId: 12, buttons: 1 });
  element.lose(12);
  assert.equal(adapter.sync.release(12, "owner", 4, element), true);
  assert.equal(adapter.debugCaptureCount(), 0);
  assert.throws(() => adapter.sync.release(12, "owner", 4), /no live capture owned by this component/);
});

test("lost pointer capture removes ownership after the deferred Ruby dispatch window", async () => {
  const element = target();
  adapter.sync.capture(element, 13, "owner", 4, { pointerId: 13, buttons: 1 });
  element.lose(13);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(adapter.debugCaptureCount(), 0);
});
