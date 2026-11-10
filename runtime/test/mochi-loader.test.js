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
  log.symbols = symbols;
  log.symbolNames = new Map();
  log.hasMethodCalls = [];
  log.dispatchedArgs = [];
  log.requiredArgs = new Map();
  log.methods = new Set(["mounted", "increment", "reset"]);
  let nextSymbol = 100;
  let nextPointer = 1024;
  let nextInstance = 1;
  let patchLength = 0;
  let emitText = "";

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
      return String(nextInstance++);
    },
    _mochi_register_binding(instance, bindingId, getterSymbol) {
      log.bindings.push({ instance, bindingId, getterSymbol });
      return 0;
    },
    _mochi_dispatch_event(instance, methodSymbol) {
      log.dispatched.push({ instance, methodSymbol });
      return 1;
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
      return 0;
    },
    _mochi_last_error_len() {
      return 0;
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
    symbols,
  };
  return module;
}

async function setup(components) {
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
  global.fetch = async (url) => {
    log.fetches.push(String(url));
    if (String(url).endsWith("mochi-manifest.json")) {
      return { ok: true, json: async () => body };
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

test("disconnect dispatches unmounted and stops routing actions", async () => {
  const { log } = await setup([COMPONENT]);
  log.methods.add("unmounted");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  element.remove();

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
  await new Promise((resolve) => setImmediate(resolve));

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

  assert.equal(log.dispatched.length, dispatchedBefore);
  assert.equal(element.mochiError, undefined);
  assert.equal(log.symbols.get("unmounted"), undefined);
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

test("binding paths resolve through text nodes and comments exactly as emitted", async () => {
  const component = {
    ...COMPONENT,
    tag_name: "path-check",
    class_name: "PathCheck",
    html_template: '\n  <div class="one"><b>text</b></div>\n  <!--if-anchor-0-->\n  <p class="two">x</p>\n',
    bindings: [
      { id: 7, path: [1, 0, 0], kind: "text", attr_name: null, template_text: "text", getter_sym: "__mochi_bind_7" },
      { id: 8, path: [3], kind: "cond", attr_name: null, template_text: "<p>shown</p>", getter_sym: "__mochi_bind_8" },
      { id: 9, path: [5, 0], kind: "html", attr_name: null, template_text: "{html}", getter_sym: "__mochi_bind_9" },
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
  assert.equal(box.hasAttribute("class"), false);
});

test("html and attribute patches update their cached targets", async () => {
  const htmlComponent = {
    tag_name: "html-check",
    class_name: "HtmlCheck",
    chi_file: "html-check.chi",
    html_template: '<span class="icon">{rendered_svg}</span>',
    css: "",
    bindings: [
      { id: 0, path: [0, 0], kind: "html", attr_name: null, template_text: "{rendered_svg}", getter_sym: "__mochi_bind_0" },
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

test("each patches reconcile keyed fragments and preserve unchanged nodes", async () => {
  const eachComponent = {
    tag_name: "each-check",
    class_name: "EachCheck",
    chi_file: "each-check.chi",
    html_template: "<!--each-anchor-0-->",
    css: "",
    bindings: [
      { id: 0, path: [0], kind: "each", attr_name: null, template_text: "<li>{name}</li>", getter_sym: "__mochi_bind_0" },
    ],
    events: [],
  };

  const { loader, module } = await setup([eachComponent]);
  module.patchQueue.push({
    patches: [{ id: 0, value: JSON.stringify([{ id: "a", name: "A" }, { id: "b", name: "B" }]) }],
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
    patches: [{ id: 0, value: JSON.stringify([{ id: "a", name: "A" }, { id: "c", name: "C" }]) }],
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
