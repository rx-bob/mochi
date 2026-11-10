const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const LOADER_PATH = path.join(__dirname, "..", "mochi-loader.js");

const HTML_TEMPLATE = [
  '<span class="count">Count: {count}</span>',
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
    { id: 0, path: [0, 0], kind: "text", attr_name: null, template_text: "Count: {count}", getter_sym: "__mochi_bind_0" },
    { id: 1, path: [2], kind: "cond", attr_name: null, template_text: "hot", getter_sym: "__mochi_bind_1" },
  ],
  events: [
    { path: [4], event: "click", method_sym: "increment", args: [] },
    { path: [6], event: "change", method_sym: "reset", args: [] },
  ],
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
  log.hasMethodCalls = [];
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
      log.interned.push(name);
      return symbols.get(name);
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
  assert.equal(root.querySelector(".count").textContent, "Count: {count}");
  assert.ok(root.querySelector("button"));

  assert.deepEqual(Object.keys(element.bindingTargets).sort(), ["0", "1"]);
  assert.equal(element.bindingTargets[0].nodeType, 3);
  assert.equal(element.bindingTargets[0].textContent, "Count: {count}");
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
  assert.equal(first.bindingTargets[0].textContent, "Count: {count}");
  assert.equal(second.bindingTargets[0].textContent, "Count: {count}");
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

  module.patchQueue.push({ patches: [{ id: 1, value: "true" }] });
  element.shadowRoot.querySelector('button[data-mochi-click="increment"]').click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(element.shadowRoot.textContent.includes("hot"), true);
  assert.equal(element.bindingTargets[1], anchor);
  assert.equal(anchor.nodeType, 8);

  module.patchQueue.push({ patches: [{ id: 1, value: "false" }] });
  element.shadowRoot.querySelector('button[data-mochi-change="reset"]').dispatchEvent(
    new global.Event("change", { bubbles: true })
  );
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(element.shadowRoot.textContent.includes("hot"), false);
  assert.equal(element.bindingTargets[1], anchor);
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
