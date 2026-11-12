const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const LOADER_PATH = path.join(__dirname, "..", "mochi-loader.js");

const HTML_TEMPLATE = [
  '<span class="count">Count: {@count}</span>',
  "<!--if-anchor-0-->",
  '<button data-mochi-click="increment">Increment</button>',
  '<button data-mochi-change="reset">Reset</button>',
  '<input class="probe">',
].join("\n");

const COMPONENT = {
  tag_name: "my-counter",
  class_name: "MyCounter",
  chi_file: "my-counter.chi",
  html_template: HTML_TEMPLATE,
  css: ":host { display: block; } .count { color: red; }",
  bindings: [
    { id: 0, path: [0, 0], kind: "text", attr_name: null, template_text: "Count: {@count}", getter_sym: "__mochi_bind_0" },
    { id: 1, path: [2], kind: "cond", attr_name: null, template_text: "hot", getter_sym: "__mochi_bind_1" },
  ],
  events: [
    { path: [4], event: "click", method_sym: "increment", args: [] },
    { path: [6], event: "change", method_sym: "reset", args: [] },
  ],
};

const LOGS_COMPONENT = {
  ...COMPONENT,
  tag_name: "my-logs",
  class_name: "MyLogs",
  chi_file: "my-logs.chi",
};

function manifest(components) {
  return {
    components,
    wasm_file: "mochi-gvm.wasm",
    js_file: "mochi-gvm.js",
    loader_file: "mochi-loader.js",
  };
}

// Disposal waits one microtask so a same-turn DOM move can cancel it. Tests
// that expect a final removal to complete flush that boundary explicitly.
function flushLifecycle() {
  return new Promise((resolve) => setImmediate(resolve));
}

function encodePatches(records) {
  const encoder = new TextEncoder();
  const encoded = records.map((record) => encoder.encode(record.value));
  const size = records.reduce((total, record, index) => total + 6 + encoded[index].length, 0);
  const bytes = new Uint8Array(size);
  let at = 0;
  records.forEach((record, index) => {
    bytes[at] = record.id & 0xff;
    bytes[at + 1] = (record.id >>> 8) & 0xff;
    const length = encoded[index].length;
    bytes[at + 2] = length & 0xff;
    bytes[at + 3] = (length >>> 8) & 0xff;
    bytes[at + 4] = (length >>> 16) & 0xff;
    bytes[at + 5] = (length >>> 24) & 0xff;
    bytes.set(encoded[index], at + 6);
    at += 6 + length;
  });
  return bytes;
}

function fakeModule(log) {
  const decoder = new TextDecoder();
  const symbols = new Map();
  const patchOffset = 4096;
  const emitOffset = 8192;
  const fetchOutboxOffset = 16384;
  const fetchInboxOffset = 32768;
  const fetchInboxCapacity = 16384;
  log.symbols = symbols;
  log.symbolNames = new Map();
  log.hasMethodCalls = [];
  log.dispatchedArgs = [];
  log.deliveredFetches = [];
  log.unmounts = [];
  log.ivarSets = [];
  log.components = new Set();
  log.failDispatch = new Set();
  log.errorText = "";
  log.requiredArgs = new Map();
  log.methods = new Set(["mounted", "increment", "reset"]);
  let nextSymbol = 100;
  let nextPointer = 1024;
  let nextInstance = 1;
  let patchLength = 0;
  let emitText = "";
  let fetchText = "";

  const module = {
    HEAPU8: new Uint8Array(65536),
    patchQueue: [],
    _malloc(size) {
      const pointer = nextPointer;
      nextPointer += size + 16;
      return pointer;
    },
    _free() {},
    _mochi_init_runtime() {
      log.calls.push("init_runtime");
      return 0;
    },
    _mochi_load_irep(pointer, length) {
      log.loads.push(module.HEAPU8.slice(pointer, pointer + length));
      return 0;
    },
    _mochi_intern(pointer, length) {
      const name = decoder.decode(module.HEAPU8.slice(pointer, pointer + length));
      if (!symbols.has(name)) symbols.set(name, nextSymbol++);
      const symbol = symbols.get(name);
      log.symbolNames.set(symbol, name);
      log.interned.push(name);
      return symbol;
    },
    _mochi_has_method(instance, pointer, length) {
      const name = decoder.decode(module.HEAPU8.slice(pointer, pointer + length));
      log.hasMethodCalls.push(name);
      return log.methods.has(name) ? 1 : 0;
    },
    _mochi_mount_component() {
      const instance = String(nextInstance++);
      log.components.add(instance);
      return instance;
    },
    _mochi_unmount_component(instance) {
      log.unmounts.push(instance);
      log.components.delete(String(instance));
      log.bindings = log.bindings.filter((binding) => binding.instance !== instance);
      return 0;
    },
    _mochi_binding_count() {
      return log.bindings.length;
    },
    _mochi_component_count() {
      return log.components.size;
    },
    _mochi_register_binding(instance, bindingId, getterSymbol) {
      if (log.failBindingAt !== undefined && log.bindings.length + 1 === log.failBindingAt) {
        return -1;
      }
      log.bindings.push({ instance, bindingId, getterSymbol });
      return 0;
    },
    _mochi_set_ivar_string(instance, namePointer, nameLength, valuePointer, valueLength) {
      const name = decoder.decode(module.HEAPU8.slice(namePointer, namePointer + nameLength));
      const value = decoder.decode(module.HEAPU8.slice(valuePointer, valuePointer + valueLength));
      log.ivarSets.push({ instance, name, value });
      return 0;
    },
    _mochi_dispatch_event(instance, methodSymbol) {
      const name = log.symbolNames.get(methodSymbol);
      log.dispatched.push({ instance, methodSymbol });
      if (log.onDispatch) log.onDispatch(name, instance);
      return log.failDispatch.has(name) ? 0 : 1;
    },
    _mochi_dispatch_event_args(instance, methodSymbol, pointer, length) {
      const json = decoder.decode(module.HEAPU8.slice(pointer, pointer + length));
      log.dispatchedArgs.push({ instance, methodSymbol, args: JSON.parse(json) });
      return 1;
    },
    _goose_vm_method_req_argc(instance, methodSymbol) {
      const name = log.symbolNames.get(methodSymbol);
      const required = log.requiredArgs.has(name) ? log.requiredArgs.get(name) : 0;
      return BigInt(required);
    },
    _mochi_flush_patches(instance) {
      log.flushes.push(instance);
      const frame = module.patchQueue.shift() || { patches: [] };
      const bytes = encodePatches(frame.patches || []);
      module.HEAPU8.set(bytes, patchOffset);
      patchLength = bytes.length;
      return frame.count === undefined ? (frame.patches || []).length : frame.count;
    },
    _mochi_patch_buffer_offset() {
      return patchOffset;
    },
    _mochi_patch_buffer_len() {
      return patchLength;
    },
    _mochi_last_error_offset() {
      return log.errorText ? 60000 : 0;
    },
    _mochi_last_error_len() {
      if (!log.errorText) return 0;
      const bytes = new TextEncoder().encode(log.errorText);
      module.HEAPU8.set(bytes, 60000);
      return bytes.length;
    },
    _mochi_emit_outbox_offset() {
      return emitOffset;
    },
    _mochi_emit_outbox_len() {
      return emitText.length;
    },
    _mochi_emit_outbox_clear() {
      emitText = "";
    },
    queueEmit(text) {
      emitText = text;
      module.HEAPU8.set(new TextEncoder().encode(text), emitOffset);
    },
    _mochi_fetch_outbox_offset() {
      return fetchOutboxOffset;
    },
    _mochi_fetch_outbox_len() {
      return fetchText.length;
    },
    _mochi_fetch_outbox_clear() {
      fetchText = "";
    },
    _mochi_fetch_inbox_offset() {
      return fetchInboxOffset;
    },
    _mochi_fetch_inbox_capacity() {
      return fetchInboxCapacity;
    },
    _mochi_deliver_fetch(instance, callbackPointer, callbackLength, responseLength) {
      const callback = decoder.decode(
        module.HEAPU8.slice(callbackPointer, callbackPointer + callbackLength));
      const envelope = JSON.parse(decoder.decode(
        module.HEAPU8.slice(fetchInboxOffset, fetchInboxOffset + responseLength)));
      log.deliveredFetches.push({ instance, callback, envelope });
      if (log.onFetchDelivery) log.onFetchDelivery();
      return 0;
    },
    queueFetch(text) {
      fetchText = text;
      module.HEAPU8.set(new TextEncoder().encode(text), fetchOutboxOffset);
    },
    reuseInstance(value) {
      nextInstance = value;
    },
    symbols,
  };
  return module;
}

async function setup(components, options) {
  options = options || {};
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
    url: "http://localhost/",
  });

  global.window = dom.window;
  global.document = dom.window.document;
  global.HTMLElement = dom.window.HTMLElement;
  global.customElements = dom.window.customElements;
  global.Event = dom.window.Event;
  global.MouseEvent = dom.window.MouseEvent;
  global.CustomEvent = dom.window.CustomEvent;

  const log = { calls: [], fetches: [], loads: [], interned: [], bindings: [], dispatched: [], flushes: [] };
  const body = manifest(components);
  global.fetch = async (url, init) => {
    const target = String(url);
    log.fetches.push(target);
    if (target.endsWith("mochi-manifest.json")) {
      return { ok: true, json: async () => body };
    }
    if (target.endsWith(".chi") && options.classFetch) {
      return options.classFetch(target, init);
    }
    if (options.fetch && !target.endsWith(".chi")) {
      return options.fetch(target, init);
    }
    return { ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer };
  };

  delete require.cache[require.resolve(LOADER_PATH)];
  const loader = require(LOADER_PATH);
  const module = fakeModule(log);
  loader.moduleFactory = async () => module;

  await loader.boot("mochi-manifest.json");
  return { dom, loader, module, log };
}

test("boot defines a custom element with a static shadow template and scoped style", async () => {
  const { loader, module, log } = await setup([COMPONENT]);
  assert.equal(loader.components.length, 1);
  assert.ok(global.customElements.get("my-counter"));

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const root = element.shadowRoot;
  assert.ok(root);
  assert.equal(root.firstChild.tagName, "STYLE");
  assert.equal(root.firstChild.textContent, COMPONENT.css);
  assert.equal(root.querySelector(".count").textContent, "Count: {@count}");
  assert.ok(root.querySelector("button"));

  assert.deepEqual(Object.keys(element.bindingTargets).sort(), ["0", "1"]);
  assert.equal(element.bindingTargets[0].nodeType, 3);
  assert.equal(element.bindingTargets[0].textContent, "Count: {@count}");
  assert.equal(element.bindingTargets[1].nodeType, 8);
  assert.equal(element.refs, element.bindingTargets);

  assert.equal(element._mochiModule, module);
  assert.equal(element._mochiInstance, "1");
  assert.deepEqual(log.loads[0].slice(0, 10), new Uint8Array([82, 73, 84, 69, 48, 52, 48, 48, 0, 0]));
  assert.deepEqual(log.loads[0].slice(10), new Uint8Array([1, 2, 3, 4]));
  assert.equal(log.bindings.length, 2);
  assert.ok(log.interned.includes("mounted"));
});

test("delegated click and change events dispatch the interned Ruby method", async () => {
  const { log } = await setup([COMPONENT]);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));

  const incrementSymbol = log.symbols.get("increment");
  assert.ok(incrementSymbol);
  assert.deepEqual(log.dispatched.at(-1), { instance: "1", methodSymbol: incrementSymbol });

  const changeTarget = element.shadowRoot.querySelector('button[data-mochi-change="reset"]');
  changeTarget.dispatchEvent(new global.Event("change", { bubbles: true }));
  await new Promise((resolve) => setImmediate(resolve));

  const resetSymbol = log.symbols.get("reset");
  assert.ok(resetSymbol);
  assert.deepEqual(log.dispatched.at(-1), { instance: "1", methodSymbol: resetSymbol });
});

test("runtime failures report one source-mapped error and clear on remount", async () => {
  const component = {
    ...COMPONENT,
    source: { file: "lib/counter.rb", line: 3 },
    methods: { initialize: 8, increment: 12 },
  };
  const { log } = await setup([component]);
  const details = [];
  document.addEventListener("mochi:error", (error) => details.push(error.detail));

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  log.errorText = "MyCounter#increment: unknown method";
  log.failDispatch.add("increment");
  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.ok(element.mochiError);
  assert.match(element.mochiError.message, /event dispatch failed for increment/);
  assert.match(element.mochiError.message, /lib\/counter\.rb:12/);
  assert.equal(details.length, 1);
  assert.equal(details[0].phase, "event");
  assert.equal(details[0].method, "increment");
  assert.equal(details[0].source, "lib/counter.rb:12");
  assert.match(details[0].vmText, /MyCounter#increment: unknown method/);

  element.remove();
  await flushLifecycle();
  log.failDispatch.delete("increment");
  log.errorText = "";
  document.body.appendChild(element);
  await element._mochiReady;
  assert.equal(element.mochiError, undefined);
});

test("disconnect dispatches unmounted and stops routing actions", async () => {
  const { log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  element.remove();
  await flushLifecycle();

  const unmountedSymbol = log.symbols.get("unmounted");
  assert.ok(unmountedSymbol);
  assert.deepEqual(log.dispatched.at(-1), { instance: "1", methodSymbol: unmountedSymbol });
  assert.equal(element._mochiDisconnected, true);

  const dispatchedBefore = log.dispatched.length;
  document.dispatchEvent(new global.CustomEvent("mochi:action", { detail: { action: "increment" } }));
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(log.dispatched.length, dispatchedBefore);
});

test("unmounted drains emitted actions after unregistering the removed component", async () => {
  const { module, log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const first = document.createElement("my-counter");
  const second = document.createElement("my-counter");
  document.body.appendChild(first);
  document.body.appendChild(second);
  await Promise.all([first._mochiReady, second._mochiReady]);

  module.queueEmit("increment");
  first.remove();
  await flushLifecycle();

  const incrementSymbol = log.symbols.get("increment");
  assert.ok(incrementSymbol);
  const incrementDispatches = log.dispatched.filter((entry) => entry.methodSymbol === incrementSymbol);
  assert.deepEqual(incrementDispatches, [{ instance: "2", methodSymbol: incrementSymbol }]);
});

test("disconnect without an unmounted method does not dispatch or error", async () => {
  const { log } = await setup([COMPONENT]);

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const dispatchedBefore = log.dispatched.length;
  element.remove();
  await flushLifecycle();

  assert.equal(log.dispatched.length, dispatchedBefore);
  assert.equal(element.mochiError, undefined);
  assert.equal(log.symbols.get("unmounted"), undefined);
});

test("failed binding registration rolls back the partial mount and a retry succeeds", async () => {
  const { log } = await setup([COMPONENT]);
  log.failBindingAt = 2;

  const failed = document.createElement("my-counter");
  document.body.appendChild(failed);
  await assert.rejects(failed._mochiReady);

  assert.equal(failed._mochiMountState, "failed");
  assert.ok(failed.mochiError);
  assert.deepEqual(log.unmounts, ["1"]);
  assert.deepEqual(log.bindings, []);
  assert.equal(log.components.size, 0);
  failed.remove();

  log.failBindingAt = undefined;
  const retry = document.createElement("my-counter");
  document.body.appendChild(retry);
  await retry._mochiReady;

  assert.equal(retry._mochiMountState, "mounted");
  assert.equal(log.bindings.length, 2);
  assert.equal(log.components.size, 1);
  assert.deepEqual(log.unmounts, ["1"]);
});

test("mounted failure runs the unmounted hook once and discards pending host work", async () => {
  const { module, loader, log } = await setup([COMPONENT]);
  log.methods.add("unmounted");
  log.failDispatch.add("mounted");
  log.onDispatch = (name, instance) => {
    if (name !== "mounted") return;
    module.queueEmit(JSON.stringify({
      __host: "timer",
      id: 77,
      kind: "timeout",
      ms: 10,
      instance: instance,
      callback: "increment",
    }));
  };

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await assert.rejects(element._mochiReady);

  assert.ok(element.mochiError);
  assert.deepEqual(log.unmounts, ["1"]);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);
  const statistics = loader.debugStats();
  assert.equal(statistics.timers, 0);
  const unmountedSymbol = log.symbols.get("unmounted");
  assert.deepEqual(log.dispatched.filter((entry) => entry.methodSymbol === unmountedSymbol), [
    { instance: "1", methodSymbol: unmountedSymbol },
  ]);
});

test("disconnect disposes VM registrations once and clears binding caches", async () => {
  const { module, log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  const mountToken = element._mochiMountToken;
  assert.equal(log.bindings.length, 2);
  assert.equal(log.components.size, 1);

  element.remove();
  await flushLifecycle();
  assert.deepEqual(log.unmounts, ["1"]);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);
  assert.deepEqual(element.bindingTargets, {});
  assert.deepEqual(element.bindingValues, {});
  assert.equal(element._mochiMountState, "unmounted");

  element._unmount(module, "1", mountToken);
  assert.deepEqual(log.unmounts, ["1"]);
  const unmountedSymbol = log.symbols.get("unmounted");
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === unmountedSymbol).length,
    1,
  );
});

test("unmounted hook failure still removes VM registrations", async () => {
  const { log } = await setup([COMPONENT]);
  log.methods.add("unmounted");
  log.failDispatch.add("unmounted");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  element.remove();
  await flushLifecycle();

  assert.ok(element.mochiError);
  assert.match(element.mochiError.message, /unmounted dispatch failed/);
  assert.deepEqual(log.unmounts, ["1"]);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);
});

test("late fetch delivery cannot reach a component that reused the instance slot", async () => {
  let resolveResponse;
  const pending = new Promise((resolve) => { resolveResponse = resolve; });
  const { module, log } = await setup([COMPONENT], { fetch: () => pending });

  const first = document.createElement("my-counter");
  document.body.appendChild(first);
  await first._mochiReady;

  module.queueFetch(JSON.stringify({
    instance: "1",
    url: "/api/late",
    callback: "increment",
    options: {},
  }));
  first.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(log.fetches.includes("/api/late"));

  first.remove();
  await flushLifecycle();
  assert.deepEqual(log.unmounts, ["1"]);

  module.reuseInstance(1);
  const second = document.createElement("my-counter");
  document.body.appendChild(second);
  await second._mochiReady;
  assert.equal(second._mochiInstance, "1");

  resolveResponse({
    ok: true,
    status: 200,
    headers: { get: () => "application/json" },
    text: async () => JSON.stringify({ ok: true }),
  });
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(log.deliveredFetches, []);
  assert.equal(second.mochiError, undefined);
});

test("a same-turn DOM move preserves the instance, bindings, and listener set", async () => {
  const { log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const firstParent = document.createElement("div");
  const secondParent = document.createElement("div");
  document.body.appendChild(firstParent);
  document.body.appendChild(secondParent);
  const element = document.createElement("my-counter");
  firstParent.appendChild(element);
  await element._mochiReady;

  const mountToken = element._mochiMountToken;
  const mountedSymbol = log.symbols.get("mounted");
  assert.ok(mountedSymbol);

  secondParent.appendChild(element);
  await flushLifecycle();

  assert.equal(element.isConnected, true);
  assert.equal(element._mochiMountState, "mounted");
  assert.equal(element._mochiDisconnected, false);
  assert.equal(element._mochiMountToken, mountToken);
  assert.equal(element._mochiInstance, "1");
  assert.deepEqual(log.unmounts, []);
  assert.equal(log.components.size, 1);
  assert.equal(log.bindings.length, 2);
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === mountedSymbol).length,
    1,
  );

  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await flushLifecycle();
  assert.deepEqual(log.dispatched.at(-1), {
    instance: "1",
    methodSymbol: log.symbols.get("increment"),
  });
});

test("reinsertion after completed disposal mounts one fresh instance", async () => {
  const { log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  const firstToken = element._mochiMountToken;
  const mountedSymbol = log.symbols.get("mounted");

  element.remove();
  await flushLifecycle();
  const unmountedSymbol = log.symbols.get("unmounted");
  assert.ok(unmountedSymbol);

  assert.equal(element._mochiMountState, "unmounted");
  assert.deepEqual(log.unmounts, ["1"]);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);
  assert.deepEqual(element.bindingTargets, {});

  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element._mochiMountState, "mounted");
  assert.notEqual(element._mochiMountToken, firstToken);
  assert.equal(element._mochiInstance, "2");
  assert.equal(log.components.size, 1);
  assert.equal(log.bindings.length, 2);
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === mountedSymbol).length,
    2,
  );
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === unmountedSymbol).length,
    1,
  );
  assert.ok(element.shadowRoot.querySelector('button[data-mochi-click="increment"]'));

  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await flushLifecycle();
  assert.deepEqual(log.dispatched.at(-1), {
    instance: "2",
    methodSymbol: log.symbols.get("increment"),
  });

  element.remove();
  await flushLifecycle();
  assert.deepEqual(log.unmounts, ["1", "2"]);
  assert.equal(log.components.size, 0);
});

test("attribute changes update the instance and flush bindings once", async () => {
  const { dom, log } = await setup([COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const element = document.createElement("my-counter");
    element.setAttribute("label", "one");
    document.body.appendChild(element);
    await element._mochiReady;

    assert.deepEqual(log.ivarSets.at(-1), { instance: "1", name: "label", value: "one" });
    const setsAfterMount = log.ivarSets.length;
    const flushesAfterMount = log.flushes.length;

    element.setAttribute("label", "two");
    await flushLifecycle();

    assert.equal(log.ivarSets.length, setsAfterMount + 1);
    assert.deepEqual(log.ivarSets.at(-1), { instance: "1", name: "label", value: "two" });
    assert.equal(log.flushes.length, flushesAfterMount + 1);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a fresh mount replaces its attribute observer without stacking", async () => {
  const { dom } = await setup([COMPONENT]);
  const observers = [];
  const previousObserver = global.MutationObserver;
  global.MutationObserver = class {
    constructor(callback) {
      this.inner = new dom.window.MutationObserver(callback);
      this.disconnects = 0;
      observers.push(this);
    }

    observe(target, options) {
      return this.inner.observe(target, options);
    }

    disconnect() {
      this.disconnects += 1;
      return this.inner.disconnect();
    }
  };

  try {
    const element = document.createElement("my-counter");
    document.body.appendChild(element);
    await element._mochiReady;
    assert.equal(observers.length, 1);
    assert.equal(observers[0].disconnects, 0);

    element.remove();
    await flushLifecycle();
    assert.equal(observers[0].disconnects, 1);

    document.body.appendChild(element);
    await element._mochiReady;
    assert.equal(observers.length, 2);
    assert.equal(observers[0].disconnects, 1);

    element.remove();
    await flushLifecycle();
    assert.equal(observers[1].disconnects, 1);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a detached tree receives neither patches nor delegated events", async () => {
  const { loader, module, log } = await setup([COMPONENT]);

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  const incrementSymbol = log.symbols.get("increment");
  const flushesBefore = log.flushes.length;

  element.remove();
  module.patchQueue.push({ patches: [{ id: 0, value: "Count: detached" }] });
  loader.applyPatches(element, module);
  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();

  assert.equal(log.flushes.length, flushesBefore);
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === incrementSymbol).length,
    0,
  );

  await flushLifecycle();
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === incrementSymbol).length,
    0,
  );
});

test("removal during the class download cancels the mount before instance creation", async () => {
  let releaseClass;
  const classGate = new Promise((resolve) => { releaseClass = resolve; });
  const { log } = await setup([COMPONENT], { classFetch: () => classGate });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  const ready = element._mochiReady;
  element.remove();
  await flushLifecycle();

  releaseClass({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer });
  await ready;
  await flushLifecycle();

  assert.equal(element._mochiMountState, "unmounted");
  assert.deepEqual(log.unmounts, []);
  assert.deepEqual(log.dispatched, []);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);

  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element._mochiMountState, "mounted");
  assert.equal(element._mochiInstance, "1");
  assert.equal(log.components.size, 1);
  assert.equal(log.bindings.length, 2);
});

test("a reconnect during the class download keeps one pending mount", async () => {
  let releaseClass;
  const classGate = new Promise((resolve) => { releaseClass = resolve; });
  const { log } = await setup([COMPONENT], { classFetch: () => classGate });

  const firstParent = document.createElement("div");
  const secondParent = document.createElement("div");
  document.body.appendChild(firstParent);
  document.body.appendChild(secondParent);
  const element = document.createElement("my-counter");
  firstParent.appendChild(element);
  const mountToken = element._mochiMountToken;

  element.remove();
  secondParent.appendChild(element);
  releaseClass({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer });
  await element._mochiReady;
  await flushLifecycle();

  assert.equal(element._mochiMountState, "mounted");
  assert.equal(element._mochiMountToken, mountToken);
  assert.equal(element._mochiInstance, "1");
  assert.deepEqual(log.unmounts, []);
  assert.equal(log.components.size, 1);
  assert.equal(log.bindings.length, 2);
  assert.equal(log.dispatched.filter((entry) => entry.methodSymbol === log.symbols.get("mounted")).length, 1);
});

test("one document action listener serves every mounted component and caches method support", async () => {
  const { dom, log } = await setup([COMPONENT]);
  let actionListeners = 0;
  const document = dom.window.document;
  const addEventListener = document.addEventListener.bind(document);
  document.addEventListener = function (type, listener, options) {
    if (type === "mochi:action") actionListeners += 1;
    return addEventListener(type, listener, options);
  };

  const elements = [];
  for (let index = 0; index < 17; index += 1) {
    const element = document.createElement("my-counter");
    document.body.appendChild(element);
    elements.push(element);
  }
  await Promise.all(elements.map((element) => element._mochiReady));

  assert.equal(actionListeners, 1);

  const dispatchedBefore = log.dispatched.length;
  document.dispatchEvent(new global.CustomEvent("mochi:action", { detail: { action: "increment" } }));
  await new Promise((resolve) => setImmediate(resolve));

  const incrementSymbol = log.symbols.get("increment");
  assert.ok(incrementSymbol);
  assert.equal(
    log.dispatched.slice(dispatchedBefore).filter((entry) => entry.methodSymbol === incrementSymbol).length,
    17
  );
  assert.equal(log.hasMethodCalls.filter((name) => name === "increment").length, 1);

  document.dispatchEvent(new global.CustomEvent("mochi:action", { detail: { action: "increment" } }));
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(
    log.dispatched.slice(dispatchedBefore).filter((entry) => entry.methodSymbol === incrementSymbol).length,
    34
  );
  assert.equal(log.hasMethodCalls.filter((name) => name === "increment").length, 1);
  assert.equal(actionListeners, 1);
});

test("action payloads reach one-argument handlers and target tags filter sibling components", async () => {
  const { module, log } = await setup([COMPONENT, LOGS_COMPONENT]);
  log.methods.add("select_trace");
  log.requiredArgs.set("select_trace", 1);

  const counter = document.createElement("my-counter");
  const firstLogs = document.createElement("my-logs");
  const secondLogs = document.createElement("my-logs");
  document.body.appendChild(counter);
  document.body.appendChild(firstLogs);
  document.body.appendChild(secondLogs);
  await Promise.all([counter._mochiReady, firstLogs._mochiReady, secondLogs._mochiReady]);

  module.queueEmit(JSON.stringify({
    action: "select_trace",
    target: "my-logs",
    payload: { id: "tr_9f2a" }
  }) + "\n");
  counter._dispatchAction("increment");
  await new Promise((resolve) => setImmediate(resolve));

  const selectSymbol = log.symbols.get("select_trace");
  assert.ok(selectSymbol);
  assert.deepEqual(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol),
    [
      { instance: "2", methodSymbol: selectSymbol, args: [{ id: "tr_9f2a" }] },
      { instance: "3", methodSymbol: selectSymbol, args: [{ id: "tr_9f2a" }] }
    ]
  );
  assert.equal(
    log.dispatched.filter((entry) => entry.methodSymbol === selectSymbol).length,
    0
  );
});

test("unfiltered JSON emits reach every listener and zero-argument handlers ignore payloads", async () => {
  const { module, log } = await setup([COMPONENT, LOGS_COMPONENT]);
  log.methods.add("show_home");

  const counter = document.createElement("my-counter");
  const logs = document.createElement("my-logs");
  document.body.appendChild(counter);
  document.body.appendChild(logs);
  await Promise.all([counter._mochiReady, logs._mochiReady]);

  module.queueEmit(JSON.stringify({
    action: "show_home",
    target: null,
    payload: { ignored: true }
  }) + "\n");
  counter._dispatchAction("increment");
  await new Promise((resolve) => setImmediate(resolve));

  const homeSymbol = log.symbols.get("show_home");
  assert.ok(homeSymbol);
  assert.deepEqual(
    log.dispatched.filter((entry) => entry.methodSymbol === homeSymbol),
    [
      { instance: "1", methodSymbol: homeSymbol },
      { instance: "2", methodSymbol: homeSymbol }
    ]
  );
  assert.equal(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === homeSymbol).length,
    0
  );
});

test("plain action lines and null payloads remain backwards compatible", async () => {
  const { module, log } = await setup([COMPONENT]);
  log.methods.add("select_trace");
  log.requiredArgs.set("select_trace", 1);

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit("reset\n");
  element._dispatchAction("increment");
  await new Promise((resolve) => setImmediate(resolve));

  const resetSymbol = log.symbols.get("reset");
  assert.ok(resetSymbol);
  assert.deepEqual(log.dispatched.at(-1), { instance: "1", methodSymbol: resetSymbol });

  module.queueEmit(JSON.stringify({ action: "select_trace", target: null, payload: null }) + "\n");
  element._dispatchAction("increment");
  await new Promise((resolve) => setImmediate(resolve));

  const selectSymbol = log.symbols.get("select_trace");
  assert.deepEqual(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol),
    [{ instance: "1", methodSymbol: selectSymbol, args: [null] }]
  );
});

test("drains JSON fetch requests after mount and delivers parsed responses", async () => {
  const calls = [];
  const { module, log } = await setup([COMPONENT], {
    fetch: async (url, init) => {
      calls.push({ url, init });
      return {
        status: 200,
        ok: true,
        headers: { get: () => "application/json" },
        text: async () => '{"rows":[1,2]}'
      };
    }
  });

  module.queueFetch(JSON.stringify({
    id: 1,
    instance: "1",
    url: "/api/logs",
    callback: "on_logs",
    options: { method: "GET" }
  }) + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(calls, [{ url: "/api/logs", init: { method: "GET" } }]);
  assert.deepEqual(log.deliveredFetches, [{
    instance: "1",
    callback: "on_logs",
    envelope: {
      status: 200,
      ok: true,
      body: '{"rows":[1,2]}',
      data: { rows: [1, 2] },
      error: null
    }
  }]);
});

test("fetch callback mutations flush patches into bound DOM", async () => {
  const { module, log } = await setup([COMPONENT], {
    fetch: async () => ({
      status: 200,
      ok: true,
      headers: { get: () => "application/json" },
      text: async () => '{"rows":[1]}'
    })
  });
  log.onFetchDelivery = function () {
    module.patchQueue.push({ patches: [{ id: 0, value: "9" }] });
  };
  module.queueFetch(JSON.stringify({
    id: 1,
    instance: "1",
    url: "/api/logs",
    callback: "on_logs",
    options: {}
  }) + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(element.shadowRoot.querySelector(".count").textContent, "Count: 9");
  assert.equal(element.bindingTargets[0].textContent, "Count: 9");
});

test("defers fetch requests until their target instance mounts", async () => {
  const calls = [];
  const { module, log } = await setup([COMPONENT, LOGS_COMPONENT], {
    fetch: async (url) => {
      calls.push(url);
      return { status: 200, ok: true, text: async () => "ok" };
    }
  });

  module.queueFetch(JSON.stringify({
    id: 1, instance: "2", url: "/api/logs", callback: "on_logs", options: {}
  }) + "\n");

  const first = document.createElement("my-counter");
  document.body.appendChild(first);
  await first._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, []);
  assert.deepEqual(log.deliveredFetches, []);

  const second = document.createElement("my-logs");
  document.body.appendChild(second);
  await second._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(calls, ["/api/logs"]);
  assert.equal(log.deliveredFetches.length, 1);
  assert.equal(log.deliveredFetches[0].instance, "2");
});

test("fetch delivery preserves HTTP and network error envelopes", async () => {
  const { module, log } = await setup([COMPONENT], {
    fetch: async (url) => {
      if (url === "/api/offline") throw new Error("offline");
      return {
        status: 500,
        ok: false,
        statusText: "Server Error",
        text: async () => "boom"
      };
    }
  });

  module.queueFetch([
    JSON.stringify({ id: 1, instance: "1", url: "/api/fail", callback: "on_logs", options: {} }),
    JSON.stringify({ id: 2, instance: "1", url: "/api/offline", callback: "on_logs", options: {} })
  ].join("\n") + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(
    log.deliveredFetches.map((entry) => entry.envelope).sort((left, right) => left.status - right.status),
    [
      { status: 0, ok: false, body: "", data: null, error: "offline" },
      {
        status: 500,
        ok: false,
        body: "boom",
        data: null,
        error: "HTTP 500 Server Error"
      }
    ]
  );
});

test("drains fetch requests after DOM events and action dispatches", async () => {
  const { module, log } = await setup([COMPONENT], {
    fetch: async () => ({
      status: 200,
      ok: true,
      text: async () => "ok"
    })
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueFetch(JSON.stringify({
    id: 1, instance: "1", url: "/api/event", callback: "on_logs", options: {}
  }) + "\n");
  element.shadowRoot.querySelector("button").click();
  await new Promise((resolve) => setTimeout(resolve, 0));

  module.queueFetch(JSON.stringify({
    id: 2, instance: "1", url: "/api/action", callback: "on_logs", options: {}
  }) + "\n");
  element._dispatchAction("increment");
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(
    log.deliveredFetches.map((entry) => entry.envelope.body),
    ["ok", "ok"]
  );
});

test("skips fetch delivery when the component unmounts before the response", async () => {
  let resolveFetch;
  const pending = new Promise((resolve) => { resolveFetch = resolve; });
  const { module, log } = await setup([COMPONENT], {
    fetch: () => pending
  });

  module.queueFetch(JSON.stringify({
    id: 1, instance: "1", url: "/api/slow", callback: "on_logs", options: {}
  }) + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  element.remove();
  await flushLifecycle();
  resolveFetch({
    status: 200,
    ok: true,
    text: async () => '{"late":true}'
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(log.deliveredFetches, []);
});

test("drains follow-up fetch requests after a callback completes", async () => {
  const calls = [];
  const { module, log } = await setup([COMPONENT], {
    fetch: async (url) => {
      calls.push(url);
      return { status: 200, ok: true, text: async () => "ok" };
    }
  });

  let queued = false;
  log.onFetchDelivery = function () {
    if (queued) return;
    queued = true;
    module.queueFetch(JSON.stringify({
      id: 2, instance: "1", url: "/api/follow-up", callback: "on_logs", options: {}
    }) + "\n");
  };
  module.queueFetch(JSON.stringify({
    id: 1, instance: "1", url: "/api/first", callback: "on_logs", options: {}
  }) + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(calls, ["/api/first", "/api/follow-up"]);
  assert.equal(log.deliveredFetches.length, 2);
});

test("accepts legacy pipe-delimited fetch requests", async () => {
  const calls = [];
  const { module, log } = await setup([COMPONENT], {
    fetch: async (url) => {
      calls.push(url);
      return { status: 200, ok: true, text: async () => "legacy" };
    }
  });

  module.queueFetch("1|1|/api/legacy|on_logs\n");
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(calls, ["/api/legacy"]);
  assert.equal(log.deliveredFetches[0].callback, "on_logs");
});

test("multiple instances share one class and irep but keep independent targets and state", async () => {
  const { log } = await setup([COMPONENT]);
  const first = document.createElement("my-counter");
  const second = document.createElement("my-counter");
  document.body.appendChild(first);
  document.body.appendChild(second);

  await Promise.all([first._mochiReady, second._mochiReady]);

  assert.equal(first._mochiInstance, "1");
  assert.equal(second._mochiInstance, "2");
  assert.notEqual(first.bindingTargets[0], second.bindingTargets[0]);
  assert.equal(first.bindingTargets[0].textContent, "Count: {@count}");
  assert.equal(second.bindingTargets[0].textContent, "Count: {@count}");
  assert.notEqual(first.shadowRoot, second.shadowRoot);

  const chiFetches = log.fetches.filter((url) => url.endsWith("my-counter.chi"));
  assert.equal(chiFetches.length, 1);
  assert.equal(log.loads.length, 1);
  assert.equal(log.calls.filter((call) => call === "init_runtime").length, 1);
});

test("helper bytecode loads once before components that share it", async () => {
  const first = {
    ...COMPONENT,
    tag_name: "shared-first",
    class_name: "SharedFirst",
    chi_file: "shared-first.chi",
    helper_chi: "helpers-shared.chi",
  };
  const second = {
    ...COMPONENT,
    tag_name: "shared-second",
    class_name: "SharedSecond",
    chi_file: "shared-second.chi",
    helper_chi: "helpers-shared.chi",
  };

  const { log } = await setup([first, second]);
  const firstElement = document.createElement("shared-first");
  const secondElement = document.createElement("shared-second");
  document.body.appendChild(firstElement);
  document.body.appendChild(secondElement);

  await Promise.all([firstElement._mochiReady, secondElement._mochiReady]);

  const helperFetches = log.fetches.filter((url) => url.endsWith("helpers-shared.chi"));
  assert.equal(helperFetches.length, 1);
  assert.equal(log.loads.length, 3);
  assert.ok(log.fetches.indexOf(helperFetches[0]) < log.fetches.findIndex((url) => url.endsWith("shared-first.chi")));
});

test("binding paths resolve through text nodes and comments exactly as emitted", async () => {
  const component = {
    ...COMPONENT,
    tag_name: "path-check",
    class_name: "PathCheck",
    html_template: '\n  <div class="one"><b>text</b></div>\n  <!--if-anchor-0-->\n  <p class="two">x</p>\n',
    bindings: [
      { id: 7, path: [1, 0, 0], kind: "text", attr_name: null, template_text: "text", getter_sym: "__mochi_bind_7" },
      { id: 8, path: [3], kind: "cond", attr_name: null, template_text: "<p>shown</p>", getter_sym: "__mochi_bind_8" },
      { id: 9, path: [5, 0], kind: "text_html", attr_name: null, template_text: "{html}", getter_sym: "__mochi_bind_9" },
    ],
    events: [],
  };

  const { loader } = await setup([component]);
  const element = document.createElement("path-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element.bindingTargets[7].textContent, "text");
  assert.equal(element.bindingTargets[8].nodeType, 8);
  assert.equal(element.bindingTargets[9].nodeType, 1);
  assert.equal(element.bindingTargets[9].textContent, "x");
  assert.equal(element.shadowRoot.querySelectorAll("style").length, 1);
  assert.equal(element.shadowRoot.querySelectorAll("template").length, 0);
  assert.equal(loader.components[0].tag_name, "path-check");
});

test("initial flush applies text and conditional patches", async () => {
  const { module } = await setup([COMPONENT]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "7" },
      { id: 1, value: "true" },
    ],
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const count = element.shadowRoot.querySelector(".count");
  assert.equal(count.textContent, "Count: 7");
  assert.equal(element.bindingTargets[0], count.firstChild);
  assert.equal(element.bindingTargets[1].nodeType, 8);
  assert.equal(element.shadowRoot.textContent.includes("hot"), true);
  assert.equal(element.shadowRoot.querySelectorAll("template").length, 0);
});

test("applyPatches accepts a mounted instance id", async () => {
  const { loader, module } = await setup([COMPONENT]);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.patchQueue.push({ patches: [{ id: 0, value: "3" }] });
  loader.applyPatches(element._mochiInstance);

  assert.equal(element.shadowRoot.querySelector(".count").textContent, "Count: 3");
});

test("100 text updates keep sibling DOM nodes identical", async () => {
  const { module } = await setup([COMPONENT]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "0" },
      { id: 1, value: "false" },
    ],
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const count = element.shadowRoot.querySelector(".count");
  const countText = count.firstChild;
  const button = element.shadowRoot.querySelector('button[data-mochi-click="increment"]');
  const input = element.shadowRoot.querySelector("input.probe");
  const anchor = element.bindingTargets[1];

  for (let i = 1; i <= 100; i++) {
    module.patchQueue.push({ patches: [{ id: 0, value: String(i) }, { id: 1, value: "false" }] });
    button.click();
  }
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(count.textContent, "Count: 100");
  assert.equal(count.firstChild, countText);
  assert.equal(element.shadowRoot.querySelector('button[data-mochi-click="increment"]'), button);
  assert.equal(element.shadowRoot.querySelector("input.probe"), input);
  assert.equal(element.bindingTargets[1], anchor);
  assert.equal(anchor.nodeType, 8);
});

test("zero-record flushes leave the DOM untouched", async () => {
  const { module, log } = await setup([COMPONENT]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "0" },
      { id: 1, value: "false" },
    ],
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const count = element.shadowRoot.querySelector(".count");
  const text = count.firstChild;
  const button = element.shadowRoot.querySelector('button[data-mochi-click="increment"]');
  const input = element.shadowRoot.querySelector("input.probe");
  const flushCount = log.flushes.length;

  button.click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(log.flushes.length, flushCount + 1);
  assert.equal(count.textContent, "Count: 0");
  assert.equal(count.firstChild, text);
  assert.equal(element.shadowRoot.querySelector('button[data-mochi-click="increment"]'), button);
  assert.equal(element.shadowRoot.querySelector("input.probe"), input);
});

test("conditional patches mount and unmount content while preserving the anchor", async () => {
  const { module } = await setup([COMPONENT]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "0" },
      { id: 1, value: "false" },
    ],
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const anchor = element.bindingTargets[1];
  assert.equal(element.shadowRoot.textContent.includes("hot"), false);

  module.patchQueue.push({ patches: [{ id: 1, value: "0" }] });
  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(element.shadowRoot.textContent.includes("hot"), true);
  assert.equal(element.bindingTargets[1], anchor);
  assert.equal(anchor.nodeType, 8);

  module.patchQueue.push({ patches: [{ id: 1, value: "-1" }] });
  element.shadowRoot.querySelector('button[data-mochi-change="reset"]').dispatchEvent(
    new global.Event("change", { bubbles: true })
  );
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(element.shadowRoot.textContent.includes("hot"), false);
  assert.equal(element.bindingTargets[1], anchor);

  module.patchQueue.push({ patches: [{ id: 1, value: "true" }] });
  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(element.shadowRoot.textContent.includes("hot"), true);

  module.patchQueue.push({ patches: [{ id: 1, value: "false" }] });
  element.shadowRoot.querySelector('button[data-mochi-change="reset"]').dispatchEvent(
    new global.Event("change", { bubbles: true })
  );
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(element.shadowRoot.textContent.includes("hot"), false);
});

test("conditional branches replay cached child values and keep live targets on inner updates", async () => {
  const toastComponent = {
    tag_name: "toast-check",
    class_name: "ToastCheck",
    chi_file: "toast-check.chi",
    html_template: "<!--if-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "cond",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_bind_0",
        branches: [
          {
            html_template:
              '<div class="toast"><span class="toast-message">{@toast_message}</span>' +
              '<button data-mochi-click="dismiss">Dismiss</button></div>',
            bindings: [
              {
                id: 1,
                path: [0, 0, 0],
                kind: "text",
                attr_name: null,
                template_text: "{@toast_message}",
                getter_sym: "__mochi_bind_1",
              },
            ],
            events: [{ path: [0, 1], event: "click", method_sym: "dismiss", args: [] }],
          },
        ],
      },
    ],
    events: [],
  };

  const { loader, module, log } = await setup([toastComponent]);
  log.methods.add("dismiss");
  module.patchQueue.push({
    patches: [
      { id: 1, value: "Hello" },
      { id: 0, value: "0" },
    ],
  });

  const element = document.createElement("toast-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.deepEqual(log.bindings.map((entry) => entry.bindingId).sort((a, b) => a - b), [0, 1]);
  assert.equal(element.shadowRoot.querySelector(".toast-message").textContent, "Hello");
  assert.equal(element.shadowRoot.textContent.includes("{@toast_message}"), false);

  const messageNode = element.bindingTargets[1];
  module.patchQueue.push({ patches: [{ id: 1, value: "Updated" }] });
  loader.applyPatches(element, module);
  assert.equal(element.bindingTargets[1], messageNode);
  assert.equal(element.shadowRoot.querySelector(".toast-message").textContent, "Updated");

  element.shadowRoot.querySelector('button[data-mochi-click="dismiss"]').click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(log.dispatched.at(-1), { instance: "1", methodSymbol: log.symbols.get("dismiss") });

  module.patchQueue.push({ patches: [{ id: 0, value: "-1" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".toast"), null);
  assert.equal(element.bindingTargets[1], undefined);
  assert.equal(element.bindingTargets[0].nodeType, 8);

  module.patchQueue.push({ patches: [{ id: 0, value: "0" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".toast-message").textContent, "Updated");
});

test("if/elsif/else branches mount only the active branch and update inner text in place", async () => {
  const chainComponent = {
    tag_name: "chain-check",
    class_name: "ChainCheck",
    chi_file: "chain-check.chi",
    html_template: "<!--if-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "cond",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_bind_0",
        branches: [
          {
            html_template: '<p class="a">{@a}</p>',
            bindings: [
              { id: 1, path: [0, 0], kind: "text", attr_name: null, template_text: "{@a}", getter_sym: "__mochi_bind_1" },
            ],
            events: [],
          },
          {
            html_template: '<p class="b">{@b}</p>',
            bindings: [
              { id: 2, path: [0, 0], kind: "text", attr_name: null, template_text: "{@b}", getter_sym: "__mochi_bind_2" },
            ],
            events: [],
          },
          {
            html_template: '<p class="c">{@c}</p>',
            bindings: [
              { id: 3, path: [0, 0], kind: "text", attr_name: null, template_text: "{@c}", getter_sym: "__mochi_bind_3" },
            ],
            events: [],
          },
        ],
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([chainComponent]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "0" },
      { id: 1, value: "A" },
      { id: 2, value: "B" },
      { id: 3, value: "C" },
    ],
  });

  const element = document.createElement("chain-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element.shadowRoot.querySelector(".a").textContent, "A");
  assert.equal(element.shadowRoot.querySelector(".b"), null);
  assert.equal(element.shadowRoot.querySelector(".c"), null);

  module.patchQueue.push({ patches: [{ id: 0, value: "1" }] });
  loader.applyPatches(element, module);
  const branchB = element.shadowRoot.querySelector(".b");
  const branchBText = branchB.firstChild;
  assert.equal(branchB.textContent, "B");
  assert.equal(element.shadowRoot.querySelector(".a"), null);
  assert.equal(element.shadowRoot.querySelector(".c"), null);

  module.patchQueue.push({ patches: [{ id: 2, value: "B2" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".b"), branchB);
  assert.equal(element.shadowRoot.querySelector(".b").firstChild, branchBText);
  assert.equal(branchB.textContent, "B2");

  module.patchQueue.push({ patches: [{ id: 0, value: "2" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".c").textContent, "C");
  assert.equal(element.shadowRoot.querySelector(".a"), null);
  assert.equal(element.shadowRoot.querySelector(".b"), null);

  module.patchQueue.push({ patches: [{ id: 0, value: "-1" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".a"), null);
  assert.equal(element.shadowRoot.querySelector(".b"), null);
  assert.equal(element.shadowRoot.querySelector(".c"), null);
  assert.equal(element.bindingTargets[0].nodeType, 8);

  module.patchQueue.push({ patches: [{ id: 0, value: "true" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".a").textContent, "A");

  module.patchQueue.push({ patches: [{ id: 0, value: "false" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".a"), null);
});

test("nested conditional branches render and update two levels deep", async () => {
  const nestedComponent = {
    tag_name: "nested-two-check",
    class_name: "NestedTwoCheck",
    chi_file: "nested-two-check.chi",
    html_template: "<!--if-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "cond",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_bind_0",
        branches: [
          {
            html_template: "<!--if-anchor-1-->",
            bindings: [
              {
                id: 1,
                path: [0],
                kind: "cond",
                attr_name: null,
                template_text: "",
                getter_sym: "__mochi_bind_1",
                branches: [
                  {
                    html_template: '<span class="two">{@value}</span>',
                    bindings: [
                      { id: 2, path: [0, 0], kind: "text", attr_name: null, template_text: "{@value}", getter_sym: "__mochi_bind_2" },
                    ],
                    events: [],
                  },
                ],
              },
            ],
            events: [],
          },
        ],
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([nestedComponent]);
  module.patchQueue.push({
    patches: [
      { id: 2, value: "two" },
      { id: 1, value: "0" },
      { id: 0, value: "0" },
    ],
  });

  const element = document.createElement("nested-two-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element.shadowRoot.querySelector(".two").textContent, "two");

  module.patchQueue.push({ patches: [{ id: 2, value: "two2" }] });
  loader.applyPatches(element, module);
  const two = element.shadowRoot.querySelector(".two");
  const twoText = two.firstChild;
  assert.equal(two.textContent, "two2");
  assert.equal(element.shadowRoot.querySelector(".two"), two);
  assert.equal(two.firstChild, twoText);

  module.patchQueue.push({ patches: [{ id: 1, value: "-1" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".two"), null);

  module.patchQueue.push({ patches: [{ id: 1, value: "0" }] });
  loader.applyPatches(element, module);
  assert.notEqual(element.shadowRoot.querySelector(".two"), two);
  assert.equal(element.shadowRoot.querySelector(".two").textContent, "two2");
});

test("nested conditional branches render and update three levels deep", async () => {
  const nestedComponent = {
    tag_name: "nested-check",
    class_name: "NestedCheck",
    chi_file: "nested-check.chi",
    html_template: "<!--if-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "cond",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_bind_0",
        branches: [
          {
            html_template: '<span class="level2">{@outer}</span><!--if-anchor-1-->',
            bindings: [
              { id: 1, path: [0, 0], kind: "text", attr_name: null, template_text: "{@outer}", getter_sym: "__mochi_bind_1" },
              {
                id: 2,
                path: [1],
                kind: "cond",
                attr_name: null,
                template_text: "",
                getter_sym: "__mochi_bind_2",
                branches: [
                  {
                    html_template: '<div class="level3"><!--if-anchor-2--></div>',
                    bindings: [
                      {
                        id: 3,
                        path: [0, 0],
                        kind: "cond",
                        attr_name: null,
                        template_text: "",
                        getter_sym: "__mochi_bind_3",
                        branches: [
                          {
                            html_template: '<b class="level4" title="{@tip}">{@deep}</b>',
                            bindings: [
                              { id: 4, path: [0], kind: "attr", attr_name: "title", template_text: "{@tip}", getter_sym: "__mochi_bind_4" },
                              { id: 5, path: [0, 0], kind: "text", attr_name: null, template_text: "{@deep}", getter_sym: "__mochi_bind_5" },
                            ],
                            events: [],
                          },
                          { html_template: '<i class="other">other</i>', bindings: [], events: [] },
                        ],
                      },
                    ],
                    events: [],
                  },
                ],
              },
            ],
            events: [],
          },
        ],
      },
    ],
    events: [],
  };

  const { loader, module, log } = await setup([nestedComponent]);
  module.patchQueue.push({
    patches: [
      { id: 1, value: "outer" },
      { id: 2, value: "0" },
      { id: 3, value: "0" },
      { id: 4, value: "tip" },
      { id: 5, value: "deep" },
      { id: 0, value: "0" },
    ],
  });

  const element = document.createElement("nested-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.deepEqual(log.bindings.map((entry) => entry.bindingId).sort((a, b) => a - b), [0, 1, 2, 3, 4, 5]);
  assert.equal(element.shadowRoot.querySelector(".level2").textContent, "outer");
  const levelFour = element.shadowRoot.querySelector(".level4");
  assert.equal(levelFour.textContent, "deep");
  assert.equal(levelFour.getAttribute("title"), "tip");

  module.patchQueue.push({ patches: [{ id: 5, value: "deep2" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level4"), levelFour);
  assert.equal(levelFour.textContent, "deep2");

  module.patchQueue.push({ patches: [{ id: 4, value: "tip2" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level4"), levelFour);
  assert.equal(levelFour.getAttribute("title"), "tip2");

  module.patchQueue.push({ patches: [{ id: 1, value: "outer2" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level2").textContent, "outer2");

  module.patchQueue.push({ patches: [{ id: 3, value: "1" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level4"), null);
  assert.equal(element.shadowRoot.querySelector(".other").textContent, "other");

  module.patchQueue.push({ patches: [{ id: 3, value: "0" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level4").textContent, "deep2");
  assert.equal(element.shadowRoot.querySelector(".level4").getAttribute("title"), "tip2");
  assert.equal(element.shadowRoot.querySelector(".level2").textContent, "outer2");

  module.patchQueue.push({ patches: [{ id: 0, value: "-1" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level2"), null);
  assert.equal(element.shadowRoot.querySelector(".level4"), null);

  module.patchQueue.push({ patches: [{ id: 0, value: "0" }] });
  loader.applyPatches(element, module);
  assert.equal(element.shadowRoot.querySelector(".level2").textContent, "outer2");
  assert.equal(element.shadowRoot.querySelector(".level4").textContent, "deep2");
});

test("strict @ivar, method, and attribute conditional placeholders patch in place", async () => {
  const strictComponent = {
    tag_name: "strict-check",
    class_name: "StrictCheck",
    chi_file: "strict-check.chi",
    html_template:
      '<span class="count">{@count}</span>' +
      '<span class="state">{box_class}</span>' +
      '<div class="box {__mochi_attr_cond_0}">Box</div>',
    css: "",
    bindings: [
      { id: 0, path: [0, 0], kind: "text", attr_name: null, template_text: "{@count}", getter_sym: "__mochi_bind_0" },
      { id: 1, path: [1, 0], kind: "text", attr_name: null, template_text: "{box_class}", getter_sym: "__mochi_bind_1" },
      { id: 2, path: [2], kind: "attr", attr_name: "class", template_text: "box {__mochi_attr_cond_0}", getter_sym: "__mochi_bind_2" },
    ],
    events: [],
  };

  const { loader, module } = await setup([strictComponent]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "3" },
      { id: 1, value: "on" },
      { id: 2, value: "active" },
    ],
  });

  const element = document.createElement("strict-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const box = element.shadowRoot.querySelector(".box");
  assert.equal(element.shadowRoot.querySelector(".count").textContent, "3");
  assert.equal(element.shadowRoot.querySelector(".state").textContent, "on");
  assert.equal(box.getAttribute("class"), "box active");

  module.patchQueue.push({ patches: [{ id: 2, value: "" }] });
  loader.applyPatches(element, module);
  // The literal `box` prefix survives an empty conditional placeholder; only
  // a template made solely of the placeholder removes the attribute.
  assert.equal(box.classList.contains("box"), true);
  assert.equal(box.classList.contains("active"), false);
});

test("compiler placeholder ranges preserve nested and literal braces", async () => {
  const mixedText = 'Literal \uE000braces\uE001 and {format(@h["key"], {a: 1})}';
  const mixedStart = Buffer.byteLength(mixedText.slice(0, mixedText.indexOf("{format")), "utf8");
  const nestedAttr = "{format(@h['key'], '}')}";
  const component = {
    tag_name: "range-check",
    class_name: "RangeCheck",
    chi_file: "range-check.chi",
    html_template:
      '<span class="mixed">Literal {braces} and {format(@h["key"], {a: 1})}</span>' +
      `<a class="nested" title="${nestedAttr}">link</a>`,
    css: "",
    bindings: [
      {
        id: 0,
        path: [0, 0],
        kind: "text",
        attr_name: null,
        template_text: mixedText,
        getter_sym: "__mochi_bind_0",
        template_start: mixedStart,
        template_end: Buffer.byteLength(mixedText, "utf8"),
      },
      {
        id: 1,
        path: [1],
        kind: "attr",
        attr_name: "title",
        template_text: nestedAttr,
        getter_sym: "__mochi_bind_1",
        template_start: 0,
        template_end: Buffer.byteLength(nestedAttr, "utf8"),
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([component]);
  module.patchQueue.push({ patches: [{ id: 0, value: "ok" }, { id: 1, value: "tip" }] });
  const element = document.createElement("range-check");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element.shadowRoot.querySelector(".mixed").textContent, "Literal {braces} and ok");
  assert.equal(element.shadowRoot.querySelector(".nested").getAttribute("title"), "tip");

  module.patchQueue.push({ patches: [{ id: 1, value: "" }] });
  loader.applyPatches(element);
  assert.equal(element.shadowRoot.querySelector(".nested").hasAttribute("title"), false);
});

test("html and attribute patches update their cached targets", async () => {
  const htmlComponent = {
    tag_name: "html-check",
    class_name: "HtmlCheck",
    chi_file: "html-check.chi",
    html_template: '<span class="icon">{rendered_svg}</span>',
    css: "",
    bindings: [
      { id: 0, path: [0, 0], kind: "html", trusted_markup: true, attr_name: null, template_text: "{rendered_svg}", getter_sym: "__mochi_bind_0" },
    ],
    events: [],
  };
  const attrComponent = {
    tag_name: "attr-check",
    class_name: "AttrCheck",
    chi_file: "attr-check.chi",
    html_template: '<a href="{url}">link</a>',
    css: "",
    bindings: [
      { id: 0, path: [0], kind: "attr", attr_name: "href", template_text: "{url}", getter_sym: "__mochi_bind_0" },
    ],
    events: [],
  };

  const { loader, module } = await setup([htmlComponent, attrComponent]);
  module.patchQueue.push({ patches: [{ id: 0, value: "<b>icon</b>" }] });
  const htmlElement = document.createElement("html-check");
  document.body.appendChild(htmlElement);
  await htmlElement._mochiReady;

  assert.equal(htmlElement.bindingTargets[0].nodeType, 1);
  assert.equal(htmlElement.bindingTargets[0].innerHTML, "<b>icon</b>");

  module.patchQueue.push({ patches: [{ id: 0, value: "https://example.test/path" }] });
  const attrElement = document.createElement("attr-check");
  document.body.appendChild(attrElement);
  await attrElement._mochiReady;

  const link = attrElement.bindingTargets[0];
  assert.equal(link.getAttribute("href"), "https://example.test/path");

  module.patchQueue.push({ patches: [{ id: 0, value: "" }] });
  loader.applyPatches(attrElement);
  assert.equal(link.hasAttribute("href"), false);
  assert.equal(attrElement.bindingTargets[0], link);
});

test("ordinary text bindings stay literal and only trusted markup creates elements", async () => {
  const component = {
    tag_name: "trusted-text-check",
    class_name: "TrustedTextCheck",
    chi_file: "trusted-text-check.chi",
    html_template:
      '<div class="ordinary">{value}</div>' +
      '<div class="mixed">Before {plain} {Mochi.raw(svg)} after</div>',
    css: "",
    bindings: [
      {
        id: 0,
        path: [0, 0],
        kind: "text",
        attr_name: null,
        template_text: "{value}",
        getter_sym: "__mochi_bind_0",
      },
      {
        id: 1,
        path: [1, 0],
        kind: "text_html",
        attr_name: null,
        template_text: "Before {plain} {Mochi.raw(svg)} after",
        template_start: 7,
        template_end: 14,
        getter_sym: "__mochi_bind_1",
      },
      {
        id: 2,
        path: [1, 0],
        kind: "text_html",
        trusted_markup: true,
        attr_name: null,
        template_text: "Before {plain} {Mochi.raw(svg)} after",
        template_start: 15,
        template_end: 31,
        getter_sym: "__mochi_bind_2",
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([component]);
  const hostile = '<b class="bad">& "quoted"</b><img src=x onerror="global.__mochiPwned=1">';
  module.patchQueue.push({
    patches: [
      { id: 0, value: hostile },
      { id: 1, value: "<em>plain</em> & \"quoted\"" },
      { id: 2, value: '<svg class="icon"><circle></circle></svg>' },
    ],
  });

  const element = document.createElement("trusted-text-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const ordinary = element.shadowRoot.querySelector(".ordinary");
  assert.equal(ordinary.textContent, hostile);
  assert.equal(ordinary.querySelector("b"), null);
  assert.equal(ordinary.querySelector("img"), null);
  assert.equal(global.__mochiPwned, undefined);

  const mixed = element.shadowRoot.querySelector(".mixed");
  assert.equal(mixed.querySelector("em"), null);
  assert.equal(mixed.querySelector(".icon").tagName.toLowerCase(), "svg");
  assert.equal(mixed.textContent, 'Before <em>plain</em> & "quoted"  after');

  module.patchQueue.push({ patches: [{ id: 1, value: "next & <tag>" }] });
  loader.applyPatches(element);
  assert.equal(mixed.querySelector("em"), null);
  assert.equal(mixed.querySelector("tag"), null);
  assert.equal(mixed.textContent, 'Before next & <tag>  after');
  assert.equal(mixed.querySelector(".icon").tagName.toLowerCase(), "svg");
});

test("trusted row slots render markup while row item html strings stay data", async () => {
  const component = {
    tag_name: "trusted-row-check",
    class_name: "TrustedRowCheck",
    chi_file: "trusted-row-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<li class="row">\uE0020\uE003</li>',
          bindings: [{ slot: 0, kind: "html", trusted_markup: true, attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { module } = await setup([component]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a" }, ['<svg class="icon"><circle></circle></svg>'], []],
        [{ id: "b", html: '<button class="injected" onclick="global.__mochiPwned=1">bad</button>' }, ["plain"], []],
        ["<button class=\"string-injected\">bad</button>", ["string plain"], []],
      ]),
    }],
  });

  const element = document.createElement("trusted-row-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const rows = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(rows.length, 3);
  assert.equal(rows[0].querySelector(".icon").tagName.toLowerCase(), "svg");
  assert.equal(rows[1].textContent, "plain");
  assert.equal(rows[1].querySelector("button"), null);
  assert.equal(rows[2].textContent, "string plain");
  assert.equal(rows[2].querySelector("button"), null);
  assert.equal(global.__mochiPwned, undefined);
});

test("row html bindings without trusted markup are rejected", async () => {
  const component = {
    tag_name: "untrusted-row-check",
    class_name: "UntrustedRowCheck",
    chi_file: "untrusted-row-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<li class="row">\uE0020\uE003</li>',
          bindings: [{ slot: 0, kind: "html", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { module } = await setup([component]);
  module.patchQueue.push({
    patches: [{ id: 0, value: JSON.stringify([[{ id: "a" }, ["<b>bad</b>"], []]]) }],
  });

  const element = document.createElement("untrusted-row-check");
  document.body.appendChild(element);
  await assert.rejects(element._mochiReady, /missing trusted_markup/);
  assert.equal(element.shadowRoot.querySelector("b"), null);
});

test("each patches reconcile keyed fragments and preserve unchanged nodes", async () => {
  const eachComponent = {
    tag_name: "each-check",
    class_name: "EachCheck",
    chi_file: "each-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: "<li>\uE0020\uE003</li>",
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([eachComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a", name: "A" }, ["A"], []],
        [{ id: "b", name: "B" }, ["B"], []],
      ]),
    }],
  });
  const element = document.createElement("each-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const anchor = element.bindingTargets[0];
  const firstA = element.shadowRoot.querySelectorAll("li")[0];
  const firstB = element.shadowRoot.querySelectorAll("li")[1];
  assert.equal(firstA.textContent, "A");
  assert.equal(firstB.textContent, "B");

  const removed = [];
  const removeChild = element.shadowRoot.removeChild.bind(element.shadowRoot);
  element.shadowRoot.removeChild = (node) => {
    removed.push(node);
    return removeChild(node);
  };

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a", name: "A" }, ["A"], []],
        [{ id: "c", name: "C" }, ["C"], []],
      ]),
    }],
  });
  loader.applyPatches(element);

  const items = Array.from(element.shadowRoot.querySelectorAll("li"));
  assert.deepEqual(items.map((item) => item.textContent), ["A", "C"]);
  assert.equal(items[0], firstA);
  assert.equal(items[1] === firstB, false);
  assert.equal(removed.includes(firstA), false);
  assert.equal(removed.includes(firstB), true);
  assert.equal(element.bindingTargets[0], anchor);
  assert.equal(anchor.nodeType, 8);
});

test("compiled rows mount nested lists with distinct outer and inner scopes", async () => {
  const nestedComponent = {
    tag_name: "nested-each-check",
    class_name: "NestedEachCheck",
    chi_file: "nested-each-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<div class="group"><span>\uE0020\uE003</span><!--mochi-each-1--></div>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [
            {
              id: 1,
              template: "<li>\uE0020\uE003-\uE0021\uE003-\uE0022\uE003</li>",
              bindings: [
                { slot: 0, kind: "text", attr_name: null },
                { slot: 1, kind: "text", attr_name: null },
                { slot: 2, kind: "text", attr_name: null },
              ],
              children: [],
            },
          ],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([nestedComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [
          { id: "g1", label: "G1" },
          ["G1"],
          [[[{ id: "c1", name: "c1", group: "g1" }, ["c1", "g1", 0], []]]],
        ],
        [
          { id: "g2", label: "G2" },
          ["G2"],
          [[[{ id: "c2", name: "c2", group: "g2" }, ["c2", "g2", 1], []]]],
        ],
      ]),
    }],
  });

  const element = document.createElement("nested-each-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const groups = Array.from(element.shadowRoot.querySelectorAll(".group"));
  assert.deepEqual(groups.map((group) => group.querySelector("span").textContent), ["G1", "G2"]);
  assert.deepEqual(
    Array.from(element.shadowRoot.querySelectorAll("li")).map((item) => item.textContent),
    ["c1-g1-0", "c2-g2-1"]
  );
  assert.equal(groups[0].textContent.indexOf("{"), -1);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [
          { id: "g1", label: "G1x" },
          ["G1x"],
          [[[{ id: "c1", name: "c1", group: "g1" }, ["c1", "g1", 0], []]]],
        ],
      ]),
    }],
  });
  loader.applyPatches(element);

  assert.equal(element.shadowRoot.querySelectorAll(".group").length, 1);
  assert.equal(element.shadowRoot.querySelector("span").textContent, "G1x");
  assert.equal(element.shadowRoot.querySelector("li").textContent, "c1-g1-0");
});

test("compiled row events pass outer and inner row values before the event payload", async () => {
  const rowEventComponent = {
    tag_name: "row-event-check",
    class_name: "RowEventCheck",
    chi_file: "row-event-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<div class="group"><!--mochi-each-1--></div>',
          bindings: [],
          children: [
            {
              id: 1,
              template: '<button class="row" data-mochi-click="__mochi_each_1_ev_1">\uE0020\uE003</button>',
              bindings: [{ slot: 0, kind: "text", attr_name: null }],
              children: [],
            },
          ],
        },
      },
    ],
    events: [{ path: [0], event: "click", method_sym: "open_event", args: [] }],
  };

  const { module, log } = await setup([rowEventComponent]);
  log.methods.add("open_event");
  const outerItem = { id: "g1", name: "G1" };
  const innerItem = { id: "c1", name: "C1" };
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [outerItem, [], [[[innerItem, ["C1"], []]]]],
      ]),
    }],
  });

  const element = document.createElement("row-event-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const button = element.shadowRoot.querySelector("button.row");
  assert.ok(button);
  assert.equal(button.textContent, "C1");
  button.click();
  await new Promise((resolve) => setImmediate(resolve));

  const wrapperSymbol = log.symbols.get("__mochi_each_1_ev_1");
  assert.ok(wrapperSymbol);
  const dispatched = log.dispatchedArgs.at(-1);
  assert.equal(dispatched.methodSymbol, wrapperSymbol);
  assert.deepEqual(dispatched.args.slice(0, 4), [outerItem, 0, innerItem, 0]);
  assert.equal(dispatched.args[4].type, "click");
});

test("compiled row text and attributes escape interpolated values", async () => {
  const escapeComponent = {
    tag_name: "row-escape-check",
    class_name: "RowEscapeCheck",
    chi_file: "row-escape-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<li title="\uE0021\uE003" data-literal="\uE000literal\uE001">\uE0020\uE003</li>',
          bindings: [
            { slot: 0, kind: "text", attr_name: null },
            { slot: 1, kind: "attr", attr_name: "title" },
          ],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { module } = await setup([escapeComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a" }, ['<b>&" quoted</b>', "<attr>&\"'" ], []],
      ]),
    }],
  });

  const element = document.createElement("row-escape-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const item = element.shadowRoot.querySelector("li");
  assert.equal(item.textContent, '<b>&" quoted</b>');
  assert.equal(item.querySelector("b"), null);
  assert.equal(item.getAttribute("title"), "<attr>&\"'");
  assert.equal(item.getAttribute("data-literal"), "{literal}");
  assert.equal(item.textContent.indexOf("{"), -1);
});



test("keyed rows patch scalar slots without replacing inputs, focus, or selection", async () => {
  const keyedComponent = {
    tag_name: "keyed-draft-check",
    class_name: "KeyedDraftCheck",
    chi_file: "keyed-draft-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          keyed: true,
          source: { file: "lib/keyed_drafts.rb", line: 4, column: 7 },
          template: '<li class="row"><input class="draft"><span class="label">\uE0020\uE003</span></li>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([keyedComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a" }, ["Alpha"], [], "a"],
        [{ id: "b" }, ["Beta"], [], "b"],
      ]),
    }],
  });
  const element = document.createElement("keyed-draft-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const row = element.shadowRoot.querySelector("li.row");
  const input = row.querySelector("input.draft");
  input.value = "draft-a";
  input.focus();
  input.setSelectionRange(1, 3);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a", changed: true }, ["Alpha changed"], [], "a"],
        [{ id: "b" }, ["Beta"], [], "b"],
      ]),
    }],
  });
  loader.applyPatches(element);

  assert.equal(element.shadowRoot.querySelector("li.row"), row);
  assert.equal(row.querySelector("input.draft"), input);
  assert.equal(input.value, "draft-a");
  assert.equal(element.shadowRoot.activeElement, input);
  assert.equal(input.selectionStart, 1);
  assert.equal(input.selectionEnd, 3);
  assert.equal(row.querySelector(".label").textContent, "Alpha changed");
});

test("keyed row moves preserve child component state and dispose removed rows once", async () => {
  const rowChild = {
    tag_name: "row-child-probe",
    class_name: "RowChildProbe",
    chi_file: "row-child-probe.chi",
    html_template: '<span class="child-state">child</span>',
    css: "",
    bindings: [],
    events: [],
  };
  const movingParent = {
    tag_name: "keyed-move-check",
    class_name: "KeyedMoveCheck",
    chi_file: "keyed-move-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          keyed: true,
          template: '<li class="row"><row-child-probe></row-child-probe><span class="label">\uE0020\uE003</span></li>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module, log } = await setup([rowChild, movingParent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "a" }, ["Alpha"], [], "a"],
        [{ id: "b" }, ["Beta"], [], "b"],
      ]),
    }],
  });
  const element = document.createElement("keyed-move-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const rows = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  const children = rows.map((row) => row.querySelector("row-child-probe"));
  await Promise.all(children.map((child) => child._mochiReady));
  const childInstances = children.map((child) => child._mochiInstance);
  const unmountCount = log.unmounts.length;

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [{ id: "b" }, ["Beta changed"], [], "b"],
        [{ id: "a" }, ["Alpha"], [], "a"],
      ]),
    }],
  });
  loader.applyPatches(element);
  await flushLifecycle();

  const reordered = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(reordered[0], rows[1]);
  assert.equal(reordered[1], rows[0]);
  assert.equal(reordered[0].querySelector("row-child-probe"), children[1]);
  assert.equal(reordered[1].querySelector("row-child-probe"), children[0]);
  assert.deepEqual(children.map((child) => child._mochiInstance), childInstances);
  assert.equal(log.unmounts.length, unmountCount);
  assert.equal(reordered[0].querySelector(".label").textContent, "Beta changed");

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "b" }, ["Beta changed"], [], "b"]]),
    }],
  });
  loader.applyPatches(element);
  await flushLifecycle();

  assert.equal(element.shadowRoot.querySelectorAll("li.row").length, 1);
  assert.equal(log.unmounts.length, unmountCount + 1);
});

test("prepend, reverse, and remove keep keyed node identity and current event indexes", async () => {
  const eventRows = {
    tag_name: "keyed-event-check",
    class_name: "KeyedEventCheck",
    chi_file: "keyed-event-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          keyed: true,
          template: '<li class="row"><button class="open" data-mochi-click="__mochi_each_0_ev_1">\uE0020\uE003</button></li>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [{ path: [0], event: "click", method_sym: "open_event", args: [] }],
  };

  const { loader, module, log } = await setup([eventRows]);
  const itemA = { id: "a" };
  const itemB = { id: "b" };
  const itemC = { id: "c" };
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[itemA, ["A"], [], "a"], [itemB, ["B"], [], "b"]]),
    }],
  });
  const element = document.createElement("keyed-event-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const rowA = element.shadowRoot.querySelectorAll("li.row")[0];
  const rowB = element.shadowRoot.querySelectorAll("li.row")[1];

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[itemB, ["B"], [], "b"], [itemA, ["A"], [], "a"]]),
    }],
  });
  loader.applyPatches(element);
  assert.equal(element.shadowRoot.querySelectorAll("li.row")[0], rowB);
  assert.equal(element.shadowRoot.querySelectorAll("li.row")[1], rowA);

  rowA.querySelector("button.open").click();
  await flushLifecycle();
  let dispatched = log.dispatchedArgs.at(-1);
  assert.deepEqual(dispatched.args.slice(0, 2), [itemA, 1]);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([
        [itemC, ["C"], [], "c"],
        [itemA, ["A"], [], "a"],
        [itemB, ["B"], [], "b"],
      ]),
    }],
  });
  loader.applyPatches(element);
  const prepended = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(prepended[1], rowA);
  assert.equal(prepended[2], rowB);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[itemC, ["C"], [], "c"], [itemB, ["B"], [], "b"]]),
    }],
  });
  loader.applyPatches(element);
  const remaining = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(remaining[0], prepended[0]);
  assert.equal(remaining[1], rowB);
  assert.equal(remaining.includes(rowA), false);

  remaining[1].querySelector("button.open").click();
  await flushLifecycle();
  dispatched = log.dispatchedArgs.at(-1);
  assert.deepEqual(dispatched.args.slice(0, 2), [itemB, 1]);
});

test("duplicate keyed rows fail before DOM changes and a later patch recovers", async () => {
  const duplicateComponent = {
    tag_name: "keyed-duplicate-check",
    class_name: "KeyedDuplicateCheck",
    chi_file: "keyed-duplicate-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          keyed: true,
          source: { file: "lib/keyed_duplicate.rb", line: 7, column: 3 },
          template: '<li class="row">\uE0020\uE003</li>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([duplicateComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "a" }, ["A"], [], "a"], [{ id: "b" }, ["B"], [], "b"]]),
    }],
  });
  const element = document.createElement("keyed-duplicate-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const rowsBefore = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  const anchor = element.bindingTargets[0];

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "a" }, ["A"], [], "a"], [{ id: "c" }, ["C"], [], "a"]]),
    }],
  });
  assert.throws(
    () => loader.applyPatches(element),
    /duplicate list key "a" at rows 0 and 1 in lib\/keyed_duplicate\.rb:7:3/
  );
  assert.deepEqual(Array.from(element.shadowRoot.querySelectorAll("li.row")), rowsBefore);
  assert.equal(anchor.__mochiEach.items.size, 2);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "a" }, ["A2"], [], "a"], [{ id: "c" }, ["C"], [], "c"]]),
    }],
  });
  loader.applyPatches(element);
  const recovered = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(recovered[0], rowsBefore[0]);
  assert.deepEqual(recovered.map((row) => row.textContent), ["A2", "C"]);
});

test("trusted row html slots patch between markers without replacing siblings", async () => {
  const htmlSlotComponent = {
    tag_name: "keyed-html-slot-check",
    class_name: "KeyedHtmlSlotCheck",
    chi_file: "keyed-html-slot-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          keyed: true,
          template: '<li class="row"><input class="keep"><span class="slot">\uE0020\uE003</span></li>',
          bindings: [{ slot: 0, kind: "html", trusted_markup: true, attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([htmlSlotComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "a" }, ["<b>one</b>"], [], "a"]]),
    }],
  });
  const element = document.createElement("keyed-html-slot-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const row = element.shadowRoot.querySelector("li.row");
  const input = row.querySelector("input.keep");
  const slot = row.querySelector("span.slot");
  assert.equal(slot.querySelector("b").textContent, "one");

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[{ id: "a" }, ["<i>two</i>"], [], "a"]]),
    }],
  });
  loader.applyPatches(element);

  assert.equal(element.shadowRoot.querySelector("li.row"), row);
  assert.equal(row.querySelector("input.keep"), input);
  assert.equal(row.querySelector("span.slot"), slot);
  assert.equal(slot.querySelector("b"), null);
  assert.equal(slot.querySelector("i").textContent, "two");
});

test("unkeyed rows keep positional identity while patching values", async () => {
  const positionalComponent = {
    tag_name: "positional-row-check",
    class_name: "PositionalRowCheck",
    chi_file: "positional-row-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "each",
        attr_name: null,
        template_text: "",
        getter_sym: "__mochi_each_0_rows",
        each_rows: {
          id: 0,
          template: '<li class="row">\uE0020\uE003</li>',
          bindings: [{ slot: 0, kind: "text", attr_name: null }],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { loader, module } = await setup([positionalComponent]);
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([["first", ["one"], []], ["second", ["two"], []]]),
    }],
  });
  const element = document.createElement("positional-row-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const first = element.shadowRoot.querySelectorAll("li.row")[0];
  const second = element.shadowRoot.querySelectorAll("li.row")[1];

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([["first", ["one changed"], []], ["second", ["two"], []]]),
    }],
  });
  loader.applyPatches(element);

  const rows = Array.from(element.shadowRoot.querySelectorAll("li.row"));
  assert.equal(rows[0], first);
  assert.equal(rows[1], second);
  assert.equal(rows[0].textContent, "one changed");
  assert.equal(rows[1].textContent, "two");
});

test("template event arguments pass typed literals to the VM", async () => {
  const literalArguments = JSON.stringify([
    { kind: "literal", literal_type: "string", value: "tr_9f2a" },
    { kind: "literal", literal_type: "number", value: "1" },
  ]).replace(/"/g, "&quot;");
  const eventComponent = {
    tag_name: "event-args-check",
    class_name: "EventArgsCheck",
    chi_file: "event-args-check.chi",
    html_template:
      '<button class="pick" data-mochi-click="select_row" ' +
      'data-mochi-args-click="' + literalArguments + '">Pick</button>',
    css: "",
    bindings: [],
    events: [{ path: [0], event: "click", method_sym: "select_row", args: [] }],
  };

  const { log } = await setup([eventComponent]);
  log.methods.add("select_row");
  const element = document.createElement("event-args-check");
  document.body.appendChild(element);
  await element._mochiReady;

  element.shadowRoot.querySelector(".pick").click();
  await new Promise((resolve) => setImmediate(resolve));

  const selectSymbol = log.symbols.get("select_row");
  assert.ok(selectSymbol);
  assert.deepEqual(log.dispatchedArgs.at(-1), {
    instance: "1",
    methodSymbol: selectSymbol,
    args: ["tr_9f2a", 1],
  });
  assert.equal(log.dispatched.filter((entry) => entry.methodSymbol === selectSymbol).length, 0);
});

test("zero-argument handlers receive the normalized event when Ruby requires one argument", async () => {
  const searchComponent = {
    tag_name: "event-auto-check",
    class_name: "EventAutoCheck",
    chi_file: "event-auto-check.chi",
    html_template: '<input class="search" data-mochi-input="on_search">',
    css: "",
    bindings: [],
    events: [{ path: [0], event: "input", method_sym: "on_search", args: [] }],
  };

  const { log } = await setup([searchComponent]);
  log.methods.add("on_search");
  log.requiredArgs.set("on_search", 1);
  const element = document.createElement("event-auto-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const input = element.shadowRoot.querySelector(".search");
  input.value = "mochi";
  input.dispatchEvent(new global.Event("input", { bubbles: true }));
  await new Promise((resolve) => setImmediate(resolve));

  const searchSymbol = log.symbols.get("on_search");
  assert.ok(searchSymbol);
  assert.deepEqual(log.dispatchedArgs.at(-1), {
    instance: "1",
    methodSymbol: searchSymbol,
    args: [{
      type: "input",
      value: "mochi",
      checked: false,
      key: "",
      code: "",
      shift_key: false,
      ctrl_key: false,
      meta_key: false,
      alt_key: false,
      client_x: 0,
      client_y: 0,
      offset_x: 0,
      offset_y: 0,
      button: 0,
      target_id: "",
      dataset: {},
    }],
  });
});

test("pointer and keyboard handlers receive coordinates, modifiers, and dataset", async () => {
  const pointerComponent = {
    tag_name: "event-payload-check",
    class_name: "EventPayloadCheck",
    chi_file: "event-payload-check.chi",
    html_template:
      '<button id="pointer-target" class="pointer" data-row-id="row-7" data-mochi-click="on_pointer" ' +
      'data-mochi-args-click=\'[{"kind":"event"}]\'>Pointer</button>' +
      '<input class="keys" data-mochi-keydown="on_key">',
    css: "",
    bindings: [],
    events: [
      { path: [0], event: "click", method_sym: "on_pointer", args: [] },
      { path: [1], event: "keydown", method_sym: "on_key", args: [] },
    ],
  };

  const { dom, log } = await setup([pointerComponent]);
  log.methods.add("on_pointer");
  log.methods.add("on_key");
  log.requiredArgs.set("on_key", 1);
  const element = document.createElement("event-payload-check");
  document.body.appendChild(element);
  await element._mochiReady;

  element.shadowRoot.querySelector(".pointer").dispatchEvent(new global.MouseEvent("click", {
    bubbles: true,
    clientX: 12,
    clientY: 34,
    button: 2,
  }));
  await new Promise((resolve) => setImmediate(resolve));

  const pointer = log.dispatchedArgs.at(-1).args[0];
  assert.equal(pointer.type, "click");
  assert.equal(pointer.client_x, 12);
  assert.equal(pointer.client_y, 34);
  assert.equal(pointer.button, 2);
  assert.equal(pointer.target_id, "pointer-target");
  assert.equal(pointer.dataset.rowId, "row-7");

  element.shadowRoot.querySelector(".keys").dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    key: "Enter",
    code: "Enter",
    shiftKey: true,
    ctrlKey: true,
  }));
  await new Promise((resolve) => setImmediate(resolve));

  const keyboard = log.dispatchedArgs.at(-1).args[0];
  assert.equal(keyboard.type, "keydown");
  assert.equal(keyboard.key, "Enter");
  assert.equal(keyboard.code, "Enter");
  assert.equal(keyboard.shift_key, true);
  assert.equal(keyboard.ctrl_key, true);
  assert.equal(keyboard.meta_key, false);
  assert.equal(keyboard.alt_key, false);
});

test("bind:value dispatches the event payload and reflects programmatic updates", async () => {
  const bindComponent = {
    tag_name: "bind-value-check",
    class_name: "BindValueCheck",
    chi_file: "bind-value-check.chi",
    html_template: '<input class="query" data-mochi-input="__mochi_set_query" value="{@query}">',
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "prop",
        attr_name: "value",
        template_text: "{@query}",
        getter_sym: "__mochi_bind_0",
        getter_expr: "@query",
        setter_sym: "__mochi_set_query",
      },
    ],
    events: [{ path: [0], event: "input", method_sym: "__mochi_set_query", args: [] }],
  };

  const { loader, module, log } = await setup([bindComponent]);
  log.methods.add("__mochi_set_query");
  log.requiredArgs.set("__mochi_set_query", 1);
  module.patchQueue.push({ patches: [{ id: 0, value: "start" }] });

  const element = document.createElement("bind-value-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const input = element.shadowRoot.querySelector(".query");
  assert.equal(input.value, "start");

  input.value = "typed";
  input.dispatchEvent(new global.Event("input", { bubbles: true }));
  await new Promise((resolve) => setImmediate(resolve));

  const setterSymbol = log.symbols.get("__mochi_set_query");
  assert.ok(setterSymbol);
  assert.deepEqual(log.dispatchedArgs.at(-1), {
    instance: "1",
    methodSymbol: setterSymbol,
    args: [{
      type: "input",
      value: "typed",
      checked: false,
      key: "",
      code: "",
      shift_key: false,
      ctrl_key: false,
      meta_key: false,
      alt_key: false,
      client_x: 0,
      client_y: 0,
      offset_x: 0,
      offset_y: 0,
      button: 0,
      target_id: "",
      dataset: {},
    }],
  });

  module.patchQueue.push({ patches: [{ id: 0, value: "remote" }] });
  loader.applyPatches(element);
  assert.equal(input.value, "remote");
  assert.equal(element.bindingTargets[0], input);
});

test("bind:checked updates the checkbox property from Ruby and sends checked state", async () => {
  const checkedComponent = {
    tag_name: "bind-checked-check",
    class_name: "BindCheckedCheck",
    chi_file: "bind-checked-check.chi",
    html_template: '<input type="checkbox" class="enabled" data-mochi-change="__mochi_set_enabled">',
    css: "",
    bindings: [
      {
        id: 0,
        path: [0],
        kind: "prop",
        attr_name: "checked",
        template_text: "{@enabled}",
        getter_sym: "__mochi_bind_0",
        getter_expr: "@enabled",
        setter_sym: "__mochi_set_enabled",
      },
    ],
    events: [{ path: [0], event: "change", method_sym: "__mochi_set_enabled", args: [] }],
  };

  const { loader, module, log } = await setup([checkedComponent]);
  log.methods.add("__mochi_set_enabled");
  log.requiredArgs.set("__mochi_set_enabled", 1);
  module.patchQueue.push({ patches: [{ id: 0, value: "false" }] });

  const element = document.createElement("bind-checked-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const input = element.shadowRoot.querySelector(".enabled");
  assert.equal(input.checked, false);

  input.checked = true;
  input.dispatchEvent(new global.Event("change", { bubbles: true }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(log.dispatchedArgs.at(-1).args[0].checked, true);

  module.patchQueue.push({ patches: [{ id: 0, value: "true" }] });
  loader.applyPatches(element);
  assert.equal(input.checked, true);

  module.patchQueue.push({ patches: [{ id: 0, value: "false" }] });
  loader.applyPatches(element);
  assert.equal(input.checked, false);
});
