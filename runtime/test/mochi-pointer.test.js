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

test("removing a captured target from its owner releases capture and target references", () => {
  const element = target();
  const root = { contains: (candidate) => candidate === element };
  adapter.sync.capture(element, 21, "owner", 8, { pointerId: 21, buttons: 1 });
  adapter.reconcileOwner("owner", 8, root);
  assert.equal(adapter.debugCaptureCount(), 1);

  adapter.reconcileOwner("owner", 8, { contains: () => false });
  assert.equal(element.hasPointerCapture(21), false);
  assert.equal(adapter.debugCaptureCount(), 0);
});

test("repeated capture, cancel, and disposal cycles leave no listeners or records", () => {
  for (let index = 0; index < 32; index += 1) {
    const element = target();
    const pointerId = 100 + index;
    adapter.sync.capture(element, pointerId, "cycle-owner", index,
      { pointerId, buttons: 1 });
    adapter.disposeOwner("cycle-owner", index);
    assert.equal(element.hasPointerCapture(pointerId), false);
    assert.equal((element.listeners.get("lostpointercapture") || []).length, 0);
    assert.equal(adapter.debugCaptureCount(), 0);
  }
});
