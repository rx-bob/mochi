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

function fakeModule(log) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const symbols = new Map();
  log.symbols = symbols;
  let nextSymbol = 100;
  let nextPointer = 1024;
  let nextInstance = 1;

  const module = {
    HEAPU8: new Uint8Array(65536),
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
    _mochi_last_error_offset() {
      return 0;
    },
    _mochi_last_error_len() {
      return 0;
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

  const log = { calls: [], fetches: [], loads: [], interned: [], bindings: [], dispatched: [] };
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
  assert.equal(element.bindingTargets[9].nodeType, 3);
  assert.equal(element.bindingTargets[9].textContent, "x");
  assert.equal(element.shadowRoot.querySelectorAll("style").length, 1);
  assert.equal(element.shadowRoot.querySelectorAll("template").length, 0);
  assert.equal(loader.components[0].tag_name, "path-check");
});
