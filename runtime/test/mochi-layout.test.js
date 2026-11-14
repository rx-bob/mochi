const test = require("node:test");
const assert = require("node:assert/strict");
const adapter = require("../mochi-layout.js");
let frames, observers, contexts, reads, sequence;
test.beforeEach(() => {
  frames = new Map(); observers = []; contexts = []; reads = []; sequence = 0;
  global.requestAnimationFrame = fn => { frames.set(++sequence, fn); return sequence; };
  global.cancelAnimationFrame = id => frames.delete(id);
  global.ResizeObserver = class {
    constructor(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
    observe(target, options) { this.target = target; this.options = options; }
    disconnect() { this.disconnected = true; }
  };
});
test.afterEach(() => contexts.forEach(context => adapter.disposeOwner(context.owner, context.mountToken)));
function frame() { const pending = [...frames.values()]; frames.clear(); pending.forEach(fn => fn()); }
function setup(owner = "a", mountToken = 1) {
  const target = { isConnected: true, width: 300.5, height: 200,
    getBoundingClientRect() {
      reads.push(owner);
      return { x: 10, y: 20, left: 10, top: 20, width: this.width, height: this.height,
        right: 10 + this.width, bottom: 20 + this.height };
    } };
  const context = { owner, mountToken, active: true, target, values: [], cancelled: 0,
    isLive() { return this.active; }, resolveRef(ref) { return ref === "viewport" ? this.target : null; },
    complete(value) { this.initial = value; }, notify(value) { this.values.push(value); }, cancel() { this.cancelled++; } };
  contexts.push(context);
  return { target, context };
}
const args = '["viewport"]', limits = { requests: 4 };

test("measure batches border-box CSS geometry reads and returns plain numbers", async () => {
  const { context } = setup();
  const first = adapter.async.measure(args, limits, context);
  const second = adapter.async.measure(args, limits, context);
  assert.equal(reads.length, 0);
  assert.equal(frames.size, 1);
  frame();
  assert.deepEqual(await first, { x: 10, y: 20, left: 10, top: 20, right: 310.5, bottom: 220, width: 300.5, height: 200 });
  assert.deepEqual(await second, await first);
  assert.deepEqual(reads, ["a"]);
});

test("resize coalesces, skips unchanged size and explicit cancel stops queued callbacks", async () => {
  const { context, target } = setup();
  const initial = adapter.async.observe(args, limits, context);
  frame(); await initial;
  assert.deepEqual(observers[0].options, { box: "border-box" });
  observers[0].callback(); frame();
  assert.deepEqual(context.values, []);
  target.width = 450;
  observers[0].callback(); observers[0].callback(); observers[0].callback();
  assert.equal(frames.size, 1);
  frame();
  assert.equal(context.values.length, 1);
  assert.equal(context.values[0].width, 450);
  target.height = 300; observers[0].callback();
  adapter.async.cancel(args, limits, context);
  assert.equal(frames.size, 0);
  observers[0].callback(); frame();
  assert.equal(context.values.length, 1);
  assert.equal(observers[0].disconnected, true);
});

test("all frame reads precede callbacks that can change another target", async () => {
  const a = setup("a"), b = setup("b");
  const initial = [adapter.async.observe(args, limits, a.context), adapter.async.observe(args, limits, b.context)];
  frame(); await Promise.all(initial);
  a.target.width = 400; b.target.width = 500;
  a.context.notify = () => { b.target.width = 999; };
  observers.forEach(observer => observer.callback()); frame();
  assert.equal(b.context.values[0].width, 500);
});

test("missing refs and unavailable observers reject without retaining resources", () => {
  const { context } = setup();
  assert.throws(() => adapter.async.measure('["missing"]', limits, context), /missing.*static ref/);
  assert.throws(() => adapter.async.measure('[""]', limits, context), /nonempty/);
  global.ResizeObserver = undefined;
  assert.throws(() => adapter.async.observe(args, limits, context), /unavailable/);
  assert.equal(frames.size, 0);
});

test("hidden zero boxes are finite and removed or replaced refs never deliver", async () => {
  const { context, target } = setup();
  target.width = target.height = 0;
  const initial = adapter.async.observe(args, limits, context);
  frame();
  assert.equal((await initial).width, 0);
  target.width = 30;
  observers[0].callback();
  context.target = { ...target };
  frame();
  assert.equal(observers[0].disconnected, true);
  assert.deepEqual(context.values, []);
});

test("disposal and a reused owner with a new mount drop old observer and pending reads", async () => {
  const old = setup("a", 1);
  const pending = adapter.async.observe(args, limits, old.context);
  adapter.disposeOwner("a", 1);
  const fresh = setup("a", 2);
  const initial = adapter.async.observe(args, limits, fresh.context);
  old.context.active = false;
  observers[0].callback(); frame();
  assert.equal(await pending, null);
  assert.equal((await initial).width, 300.5);
  assert.deepEqual(old.context.values, []);
  fresh.target.width = 600; observers[1].callback(); frame();
  assert.equal(fresh.context.values[0].width, 600);
  adapter.disposeOwner("a", 1); // cannot cancel the newer owner
  assert.equal(observers[1].disconnected, false);
});

test("capacity, repeated observe and branch reconciliation reuse owned records", async () => {
  const a = setup("a"), b = setup("b"), small = { requests: 1 };
  const first = adapter.async.observe(args, small, a.context);
  assert.throws(() => adapter.async.observe(args, small, b.context), /capacity exhausted/);
  const second = adapter.async.observe(args, small, a.context);
  assert.equal(await first, null);
  frame(); await second;
  a.target.isConnected = false;
  adapter.reconcileOwner("a", 1);
  const third = adapter.async.observe(args, small, b.context);
  frame(); await third;
  assert.equal(observers[1].disconnected, true);
});

test("an earlier frame callback can cancel a later initial measurement before delivery", async () => {
  const a = setup("a"), b = setup("b");
  const initial = adapter.async.observe(args, limits, a.context);
  frame(); await initial;
  a.target.width = 400;
  a.context.notify = () => adapter.async.cancel(args, limits, b.context);
  observers[0].callback();
  const pending = adapter.async.measure(args, limits, b.context);
  frame();
  assert.equal(await pending, null);
  assert.equal(b.context.initial, undefined);
  assert.equal(b.context.cancelled, 1);
});

test("one-shot callback can start another measurement at capacity one", async () => {
  const { context } = setup();
  const small = { requests: 1 };
  let next;
  context.complete = value => {
    context.initial = value;
    context.complete = () => {};
    next = adapter.async.measure(args, small, context);
  };
  const first = adapter.async.measure(args, small, context);
  frame(); await first;
  assert.equal(frames.size, 1);
  frame();
  assert.equal((await next).width, 300.5);
});
