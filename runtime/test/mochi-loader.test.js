const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const LOADER_PATH = path.join(__dirname, "..", "mochi-loader.js");
// Must match the VM's nil binding marker. Nil and empty string stay distinct.
const NIL = "\uE004";

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

const EMITTER_COMPONENT = {
  tag_name: "event-emitter",
  class_name: "EventEmitter",
  chi_file: "event-emitter.chi",
  html_template: [
    '<button class="choose" data-mochi-click="choose">Choose</button>',
    '<button class="choose-bad" data-mochi-click="choose_bad">Bad</button>',
  ].join(""),
  css: "",
  bindings: [],
  events: [
    { path: [0], event: "click", method_sym: "choose", args: [] },
    { path: [1], event: "click", method_sym: "choose_bad", args: [] },
  ],
  emits: [
    {
      name: "select",
      payload: [
        { name: "id", type: "integer" },
        { name: "label", type: "string" },
        { name: "active", type: "boolean" },
        { name: "tags", type: "array" },
        { name: "meta", type: "hash" },
      ],
      source: { file: "lib/event_row.rb", line: 3 },
    },
    {
      name: "opened",
      payload: [],
      source: { file: "lib/event_row.rb", line: 4 },
    },
  ],
};

const EVENT_PARENT_COMPONENT = {
  tag_name: "event-parent",
  class_name: "EventParent",
  chi_file: "event-parent.chi",
  html_template: [
    '<div class="wrap">',
    '<event-emitter data-mochi-select="row_selected"></event-emitter>',
    '<button class="refresh" data-mochi-click="refresh">Refresh</button>',
    "</div>",
  ].join(""),
  css: "",
  bindings: [],
  events: [
    { path: [0, 0], event: "select", method_sym: "row_selected", args: [], component: true },
    { path: [0, 1], event: "click", method_sym: "refresh", args: [] },
  ],
  emits: [],
};

const TYPED_COMPONENT = {
  tag_name: "typed-badge",
  class_name: "TypedBadge",
  chi_file: "typed-badge.chi",
  html_template: '<span class="label">{@label}</span>',
  css: "",
  bindings: [
    {
      id: 0,
      path: [0, 0],
      kind: "text",
      attr_name: null,
      template_text: "{@label}",
      getter_sym: "__mochi_bind_0",
    },
  ],
  events: [],
  props: [
    { name: "label", type: "string", default: true, source: { file: "lib/badge.rb", line: 7 } },
    { name: "count", type: "integer", default: true, source: { file: "lib/badge.rb", line: 8 } },
    { name: "ratio", type: "float", default: true, source: { file: "lib/badge.rb", line: 13 } },
    { name: "flag", type: "boolean", default: true, source: { file: "lib/badge.rb", line: 9 } },
    { name: "note", type: "string", source: { file: "lib/badge.rb", line: 10 } },
    { name: "rows", type: "array", default: true, source: { file: "lib/badge.rb", line: 11 } },
    { name: "meta", type: "hash", default: true, source: { file: "lib/badge.rb", line: 12 } },
  ],
};

function componentIndexEntry(component) {
  const entry = {
    tag_name: component.tag_name,
    class_name: component.class_name,
    descriptor: `components/${component.tag_name}.json`,
  };
  if (component.package) entry.package = component.package;
  return entry;
}

function manifest(components, resources, formatHost) {
  return {
    schema_version: 2,
    packages: {},
    components: components.map(componentIndexEntry),
    ...(resources ? { resources } : {}),
    ...(formatHost ? { format_host: formatHost } : {}),
    wasm_file: "mochi-gvm.wasm",
    js_file: "mochi-gvm.js",
    loader_file: "mochi-loader.js",
  };
}

function networkAdapter(fetchImpl) {
  const controllers = new Map();
  return {
    name: "network",
    version: 1,
    sync: {
      cancel(key) {
        const controller = controllers.get(String(key));
        if (controller) controller.abort();
        controllers.delete(String(key));
        return true;
      },
    },
    async: {
      async fetch(argsJson) {
        const request = JSON.parse(argsJson);
        const options = { ...(request.options || {}) };
        delete options.key;
        delete options.request_key;
        if (options.body && typeof options.body === "object") {
          options.body = JSON.stringify(options.body);
          options.headers = { ...(options.headers || {}) };
          if (!Object.keys(options.headers).some((name) => name.toLowerCase() === "content-type")) {
            options.headers["content-type"] = "application/json";
          }
        }
        const controller = new AbortController();
        options.signal = controller.signal;
        controllers.set(request.request_key, controller);
        try {
          const response = await fetchImpl(request.url, options);
          const body = response && typeof response.text === "function" ? await response.text() : "";
          const contentType = response && response.headers && response.headers.get
            ? response.headers.get("content-type") || "" : "";
          let data = null;
          if (body && (!contentType || contentType.includes("json"))) {
            try { data = JSON.parse(body); } catch (_) {}
          }
          const status = response && typeof response.status === "number" ? response.status : 0;
          const ok = response && typeof response.ok === "boolean"
            ? response.ok : status >= 200 && status < 300;
          return { status, ok, body, data, error: ok ? null : `HTTP ${status}${response.statusText ? ` ${response.statusText}` : ""}` };
        } catch (error) {
          return { status: 0, ok: false, body: "", data: null, error: error.message || String(error) };
        } finally {
          controllers.delete(request.request_key);
        }
      },
    },
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
  const hostInboxOffset = 49152;
  const hostInboxCapacity = 16384;
  log.symbols = symbols;
  log.symbolNames = new Map();
  log.hasMethodCalls = [];
  log.dispatchedArgs = [];
  log.deliveredFetches = [];
  log.deliveredHostResults = [];
  log.unmounts = [];
  log.ivarSets = [];
  log.mountProps = [];
  log.propSets = [];
  log.failProps = false;
  log.components = new Set();
  log.failDispatch = new Set();
  log.errorText = "";
  log.requiredArgs = new Map();
  log.failIvar = false;
  log.methods = new Set(["mounted", "increment", "reset"]);
  log.routeStates = [];
  log.routeInfos = [];
  log.storageSeeds = [];
  log.storageRemoves = [];
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
    _mochi_set_route_state(pointer, length) {
      log.routeStates.push(decoder.decode(module.HEAPU8.slice(pointer, pointer + length)));
    },
    _mochi_set_route_info(pointer, length) {
      log.routeInfos.push(JSON.parse(decoder.decode(
        module.HEAPU8.slice(pointer, pointer + length))));
    },
    _mochi_seed_storage(pointer, length, valuePointer, valueLength) {
      log.storageSeeds.push([
        decoder.decode(module.HEAPU8.slice(pointer, pointer + length)),
        decoder.decode(module.HEAPU8.slice(valuePointer, valuePointer + valueLength)),
      ]);
    },
    _mochi_remove_storage(pointer, length) {
      log.storageRemoves.push(decoder.decode(module.HEAPU8.slice(pointer, pointer + length)));
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
    _mochi_mount_component_props(namePointer, nameLength, jsonPointer, jsonLength) {
      const json = decoder.decode(module.HEAPU8.slice(jsonPointer, jsonPointer + jsonLength));
      log.mountProps.push(JSON.parse(json));
      return module._mochi_mount_component();
    },
    _mochi_set_props_json(instance, jsonPointer, jsonLength) {
      const json = decoder.decode(module.HEAPU8.slice(jsonPointer, jsonPointer + jsonLength));
      log.propSets.push({ instance, props: JSON.parse(json) });
      return log.failProps ? -1 : 0;
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
      return log.failIvar ? -1 : 0;
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
      return log.failFetchDelivery ? -1 : 0;
    },
    _mochi_host_inbox_offset() {
      return hostInboxOffset;
    },
    _mochi_host_inbox_capacity() {
      return hostInboxCapacity;
    },
    _mochi_deliver_host_result(instance, callbackPointer, callbackLength, responseLength) {
      const callback = decoder.decode(
        module.HEAPU8.slice(callbackPointer, callbackPointer + callbackLength));
      const envelope = JSON.parse(decoder.decode(
        module.HEAPU8.slice(hostInboxOffset, hostInboxOffset + responseLength)));
      log.deliveredHostResults.push({ instance, callback, envelope });
      if (log.onHostDelivery) log.onHostDelivery();
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
  const dom = new JSDOM(
    "<!doctype html><html><head><base href=\"http://localhost/\"></head><body></body></html>",
    { url: options.url || "http://localhost/" }
  );

  global.window = dom.window;
  global.document = dom.window.document;
  global.location = dom.window.location;
  global.history = dom.window.history;
  global.addEventListener = dom.window.addEventListener.bind(dom.window);
  global.removeEventListener = dom.window.removeEventListener.bind(dom.window);
  global.HTMLElement = dom.window.HTMLElement;
  global.customElements = dom.window.customElements;
  global.Event = dom.window.Event;
  global.MouseEvent = dom.window.MouseEvent;
  global.CustomEvent = dom.window.CustomEvent;
  global.CSSStyleSheet = dom.window.CSSStyleSheet;
  global.localStorage = dom.window.localStorage;

  delete global.MochiHostAdapter;
  const log = {
    calls: [], fetches: [], loads: [], interned: [], bindings: [],
    dispatched: [], flushes: [], hostUrls: [],
  };
  const body = options.manifest || manifest(components, options.resources, options.formatHost);
  if (options.fetch) {
    body.capabilities = {
      ...(body.capabilities || {}),
      network: { version: 1, host: "mochi-fetch.js", operations: { fetch: "async", cancel: "sync" }, packages: [] },
    };
  }
  const descriptors = new Map();
  components.forEach((component) => {
    descriptors.set(`components/${component.tag_name}.json`, {
      schema_version: 2,
      ...component,
      ...(options.fetch ? { capabilities: [...new Set([...(component.capabilities || []), "network"])] } : {}),
    });
  });
  Object.entries(options.descriptors || {}).forEach(([file, descriptor]) => {
    descriptors.set(file, descriptor);
  });
  const resourceBodies = options.resourceBodies || {};
  const requestPath = (target) =>
    decodeURIComponent(new URL(target, "http://localhost/").pathname.replace(/^\/+/, ""));
  global.fetch = async (url, init) => {
    const target = String(url);
    log.fetches.push(target);
    const relative = requestPath(target);
    if (target.endsWith("mochi-manifest.json")) {
      return { ok: true, json: async () => body };
    }
    if (relative.startsWith("components/") && relative.endsWith(".json")) {
      if (options.descriptorFetch) {
        const handled = options.descriptorFetch(target, init, descriptors.get(relative));
        if (handled) return handled;
      }
      if (descriptors.has(relative)) {
        return { ok: true, json: async () => descriptors.get(relative) };
      }
    }
    if (Object.prototype.hasOwnProperty.call(resourceBodies, relative)) {
      return { ok: true, text: async () => resourceBodies[relative] };
    }
    if (options.resourceFetch && !relative.endsWith(".chi")) {
      return options.resourceFetch(target, init);
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
  if (options.hostModuleFactory) loader.hostModuleFactory = options.hostModuleFactory;
  else if (options.fetch) loader.hostModuleFactory = async (url) =>
    url.endsWith("mochi-fetch.js") ? networkAdapter(global.fetch) : null;

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
  if (root.adoptedStyleSheets && root.adoptedStyleSheets.length > 0) {
    assert.equal(root.adoptedStyleSheets[0].cssRules.length, 2);
  } else {
    assert.equal(root.firstChild.tagName, "STYLE");
    assert.equal(root.firstChild.textContent, COMPONENT.css);
  }
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

test("boot registers component identities without fetching templates or bytecode", async () => {
  const { loader, log } = await setup([COMPONENT, LOGS_COMPONENT]);

  assert.deepEqual(log.fetches, ["http://localhost/mochi-manifest.json"]);
  assert.equal(log.loads.length, 0);
  assert.equal(loader.components.length, 2);
  assert.ok(global.customElements.get("my-counter"));
  assert.ok(global.customElements.get("my-logs"));
  assert.equal(loader.components[0].html_template, undefined);
});

test("route subscribers receive decoded params and query values once", async () => {
  const { loader, module, log, dom } = await setup([COMPONENT], {
    url: "http://localhost/logs/a%20b?level=warn&q=hello+world",
  });

  log.methods.add("on_route");
  log.requiredArgs.set("on_route", 1);
  const element = document.createElement("my-counter");
  const observer = document.createElement("my-counter");
  document.body.appendChild(element);
  document.body.appendChild(observer);
  await element._mochiReady;
  await observer._mochiReady;

  assert.equal(log.routeStates[0], "/logs/a b?level=warn&q=hello+world");
  assert.deepEqual(log.routeInfos[0], {
    path: "/logs/a b",
    segments: ["logs", "a b"],
    query: { level: "warn", q: "hello world" },
    search: "level=warn&q=hello+world",
    hash: false,
    href: "http://localhost/logs/a%20b?level=warn&q=hello+world",
  });

  module.queueEmit(JSON.stringify({
    __host: "route_subscribe",
    instance: String(element._mochiInstance),
  }) + "\n");
  element._dispatchAction({ action: "increment" });

  assert.equal(log.dispatchedArgs.length, 1);
  assert.equal(loader.debugStats().routeSubscribers, 1);
  assert.equal(log.dispatchedArgs[0].instance, element._mochiInstance);
  assert.deepEqual(log.dispatchedArgs[0].args, [log.routeInfos[0]]);

  module.queueEmit('{"__host":"set_route","path":"/costs?range=30d"}\n');
  element._dispatchAction({ action: "increment" });

  assert.equal(dom.window.location.pathname, "/costs");
  assert.equal(dom.window.location.search, "?range=30d");
  assert.equal(log.routeStates[log.routeStates.length - 1], "/costs?range=30d");
  assert.equal(log.dispatchedArgs.length, 2);
  assert.equal(log.dispatchedArgs[1].instance, element._mochiInstance);
  assert.deepEqual(log.dispatchedArgs[1].args, [{
    path: "/costs",
    segments: ["costs"],
    query: { range: "30d" },
    search: "range=30d",
    hash: false,
    href: "http://localhost/costs?range=30d",
  }]);

  element.remove();
  observer.remove();
  await flushLifecycle();
  assert.equal(loader.debugStats().routeSubscribers, 0);
});

test("replace navigation rewrites history while push navigation appends", async () => {
  const { module, log, dom } = await setup([COMPONENT]);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit('{"__host":"set_route","path":"/costs"}\n');
  element._dispatchAction({ action: "increment" });
  assert.equal(dom.window.location.pathname, "/costs");
  const pushedLength = dom.window.history.length;

  module.queueEmit('{"__host":"replace_route","path":"/logs?level=warn"}\n');
  element._dispatchAction({ action: "increment" });
  assert.equal(dom.window.location.pathname, "/logs");
  assert.equal(dom.window.location.search, "?level=warn");
  assert.equal(dom.window.history.length, pushedLength);
  assert.equal(log.routeStates[log.routeStates.length - 1], "/logs?level=warn");
});

test("hash routes keep the hash as the single URL owner", async () => {
  const { module, log, dom } = await setup([COMPONENT], {
    url: "http://localhost/#/logs/42?level=warn",
  });
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(log.routeInfos[0].path, "/logs/42");
  assert.deepEqual(log.routeInfos[0].query, { level: "warn" });
  assert.equal(log.routeInfos[0].hash, true);

  module.queueEmit('{"__host":"set_route","path":"/costs"}\n');
  element._dispatchAction({ action: "increment" });
  assert.equal(dom.window.location.pathname, "/");
  assert.equal(dom.window.location.hash, "#/costs");
  assert.equal(log.routeStates[log.routeStates.length - 1], "/costs");
});

test("the static entry file resolves as the root route", async () => {
  const { log } = await setup([COMPONENT], { url: "http://localhost/index.html" });
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(log.routeInfos[0].path, "/");
  assert.deepEqual(log.routeInfos[0].segments, []);
  assert.equal(log.routeStates[0], "/");
});

test("popstate resynchronizes the route and notifies subscribers", async () => {
  const { module, log, dom } = await setup([COMPONENT]);
  log.methods.add("on_route");
  log.requiredArgs.set("on_route", 1);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit(JSON.stringify({
    __host: "route_subscribe",
    instance: String(element._mochiInstance),
  }) + "\n");
  element._dispatchAction({ action: "increment" });
  assert.equal(log.dispatchedArgs.length, 1);

  dom.window.history.pushState({}, "", "/logs?level=warn");
  dom.window.dispatchEvent(new dom.window.Event("popstate"));

  assert.equal(log.routeStates[log.routeStates.length - 1], "/logs?level=warn");
  assert.equal(log.dispatchedArgs.length, 2);
  assert.deepEqual(log.dispatchedArgs[1].args, [{
    path: "/logs",
    segments: ["logs"],
    query: { level: "warn" },
    search: "level=warn",
    hash: false,
    href: "http://localhost/logs?level=warn",
  }]);
});

test("storage subscribers receive one deterministic initial value and effective changes", async () => {
  const { module, log, dom } = await setup([COMPONENT]);
  dom.window.localStorage.setItem("cowboy_theme", "light");
  log.methods.add("on_theme");
  log.requiredArgs.set("on_theme", 1);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit(JSON.stringify({
    __host: "storage_subscribe",
    key: "cowboy_theme",
    instance: String(element._mochiInstance),
    callback: "on_theme",
  }) + "\n");
  element._dispatchAction({ action: "increment" });

  assert.equal(log.dispatchedArgs.length, 1);
  assert.deepEqual(log.dispatchedArgs[0].args, [{
    key: "cowboy_theme",
    value: "light",
    previous: null,
    source: "initial",
    ok: true,
    error: "",
  }]);

  module.queueEmit('{"__host":"storage_set","key":"cowboy_theme","value":"dark"}\n');
  element._dispatchAction({ action: "increment" });

  assert.equal(log.dispatchedArgs.length, 2);
  assert.deepEqual(log.dispatchedArgs[1].args, [{
    key: "cowboy_theme",
    value: "dark",
    previous: "light",
    source: "same_tab",
    ok: true,
    error: "",
  }]);

  module.queueEmit('{"__host":"storage_set","key":"cowboy_theme","value":"dark"}\n');
  element._dispatchAction({ action: "increment" });
  assert.equal(log.dispatchedArgs.length, 2);
  assert.equal(dom.window.localStorage.getItem("cowboy_theme"), "dark");
});

test("storage delivers raw text so Ruby owns corrupt-value fallback", async () => {
  const { module, log, dom } = await setup([COMPONENT]);
  dom.window.localStorage.setItem("cowboy_theme", "sepia");
  log.methods.add("on_theme");
  log.requiredArgs.set("on_theme", 1);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit(JSON.stringify({
    __host: "storage_subscribe",
    key: "cowboy_theme",
    instance: String(element._mochiInstance),
    callback: "on_theme",
  }) + "\n");
  element._dispatchAction({ action: "increment" });

  assert.equal(log.dispatchedArgs.length, 1);
  assert.equal(log.dispatchedArgs[0].args[0].value, "sepia");
  assert.equal(log.dispatchedArgs[0].args[0].ok, true);

  module.queueEmit('{"__host":"storage_set","key":"cowboy_theme","value":"light"}\n');
  element._dispatchAction({ action: "increment" });
  assert.equal(log.dispatchedArgs.length, 2);
  assert.equal(log.dispatchedArgs[1].args[0].previous, "sepia");
  assert.equal(log.dispatchedArgs[1].args[0].value, "light");
});

test("storage events update the VM, removals reach subscribers, and unmount unsubscribes", async () => {
  const { loader, module, log, dom } = await setup([COMPONENT]);
  dom.window.localStorage.setItem("cowboy_theme", "light");
  log.methods.add("on_theme");
  log.requiredArgs.set("on_theme", 1);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit(JSON.stringify({
    __host: "storage_subscribe",
    key: "cowboy_theme",
    instance: String(element._mochiInstance),
    callback: "on_theme",
  }) + "\n");
  element._dispatchAction({ action: "increment" });
  assert.equal(log.dispatchedArgs.length, 1);
  assert.equal(loader.debugStats().storageSubscribers, 1);
  assert.equal(loader.debugStats().storageSubscriptionKeys, 1);

  dom.window.localStorage.setItem("cowboy_theme", "dark");
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", {
    key: "cowboy_theme",
    oldValue: "light",
    newValue: "dark",
    storageArea: dom.window.localStorage,
  }));
  assert.equal(log.dispatchedArgs.length, 2);
  assert.equal(log.dispatchedArgs[1].args[0].source, "external");
  assert.equal(log.dispatchedArgs[1].args[0].value, "dark");
  assert.deepEqual(log.storageSeeds[log.storageSeeds.length - 1], ["cowboy_theme", "dark"]);

  dom.window.localStorage.removeItem("cowboy_theme");
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", {
    key: "cowboy_theme",
    oldValue: "dark",
    newValue: null,
    storageArea: dom.window.localStorage,
  }));
  assert.equal(log.dispatchedArgs.length, 3);
  assert.equal(log.dispatchedArgs[2].args[0].value, null);
  assert.equal(log.storageRemoves[log.storageRemoves.length - 1], "cowboy_theme");

  element.remove();
  await flushLifecycle();
  assert.equal(loader.debugStats().storageSubscribers, 0);
  assert.equal(loader.debugStats().storageSubscriptionKeys, 0);
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", {
    key: "cowboy_theme",
    oldValue: null,
    newValue: "light",
    storageArea: dom.window.localStorage,
  }));
  assert.equal(log.dispatchedArgs.length, 3);
});

test("storage failures roll back the VM value and reach Ruby as one error payload", async () => {
  const { module, log, dom } = await setup([COMPONENT]);
  dom.window.localStorage.setItem("cowboy_theme", "light");
  log.methods.add("on_theme");
  log.requiredArgs.set("on_theme", 1);
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  module.queueEmit(JSON.stringify({
    __host: "storage_subscribe",
    key: "cowboy_theme",
    instance: String(element._mochiInstance),
    callback: "on_theme",
  }) + "\n");
  element._dispatchAction({ action: "increment" });

  const backing = new Map([["cowboy_theme", "light"]]);
  global.localStorage = {
    get length() { return backing.size; },
    key(index) { return Array.from(backing.keys())[index] || null; },
    getItem(key) { return backing.has(key) ? backing.get(key) : null; },
    setItem() {
      const error = new Error("quota");
      error.name = "QuotaExceededError";
      throw error;
    },
    removeItem(key) { backing.delete(key); },
  };

  module.queueEmit('{"__host":"storage_set","key":"cowboy_theme","value":"dark"}\n');
  element._dispatchAction({ action: "increment" });

  assert.equal(log.dispatchedArgs.length, 2);
  assert.deepEqual(log.dispatchedArgs[1].args, [{
    key: "cowboy_theme",
    value: "light",
    previous: "light",
    source: "same_tab",
    ok: false,
    error: "quota",
  }]);
  assert.deepEqual(log.storageSeeds[log.storageSeeds.length - 1], ["cowboy_theme", "light"]);

  global.localStorage = {
    getItem() {
      const error = new Error("blocked");
      error.name = "SecurityError";
      throw error;
    },
  };
  module.queueEmit(JSON.stringify({
    __host: "storage_subscribe",
    key: "cowboy_theme",
    instance: String(element._mochiInstance),
    callback: "on_theme",
  }) + "\n");
  element._dispatchAction({ action: "increment" });
  assert.equal(log.dispatchedArgs.length, 3);
  assert.deepEqual(log.dispatchedArgs[2].args, [{
    key: "cowboy_theme",
    value: null,
    previous: null,
    source: "initial",
    ok: false,
    error: "unavailable",
  }]);
});

test("a component descriptor with a mismatched schema fails with its identity", async () => {
  const { dom } = await setup([COMPONENT], {
    descriptors: {
      "components/my-counter.json": {
        schema_version: 1,
        tag_name: "my-counter",
        class_name: "MyCounter",
        html_template: "",
        bindings: [],
        events: [],
      },
    },
  });

  const element = dom.window.document.createElement("my-counter");
  dom.window.document.body.appendChild(element);
  await assert.rejects(
    element._mochiReady,
    /component descriptor for 'my-counter' uses schema 1 .*loader supports schema 2/,
  );
});

test("a failed descriptor load reports the component and can be retried", async () => {
  let attempts = 0;
  const { dom, loader, module, log } = await setup([COMPONENT, LOGS_COMPONENT], {
    descriptorFetch: (url) => {
      if (!url.endsWith("my-counter.json")) return null;
      attempts += 1;
      if (attempts === 1) return { ok: false, status: 503 };
      return null;
    },
  });
  const errors = [];
  loader.onError = (info) => errors.push(info);

  const logs = dom.window.document.createElement("my-logs");
  dom.window.document.body.appendChild(logs);
  await logs._mochiReady;

  const element = dom.window.document.createElement("my-counter");
  dom.window.document.body.appendChild(element);
  await assert.rejects(
    element._mochiReady,
    /failed to fetch descriptor for component 'my-counter'.*HTTP 503/,
  );
  assert.equal(errors.length, 1);
  assert.equal(errors[0].tagName, "my-counter");
  assert.equal(errors[0].phase, "descriptor");

  // The unrelated screen keeps working through the failed feature load.
  module.patchQueue.push({ patches: [{ id: 0, value: "9" }] });
  loader.applyPatches(logs, module);
  assert.equal(logs.shadowRoot.querySelector(".count").textContent, "Count: 9");

  element.remove();
  await flushLifecycle();
  dom.window.document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element._mochiMountState, "mounted");
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 2);
});

test("removal during the descriptor download does not mount an abandoned instance", async () => {
  let releaseDescriptor;
  const descriptorGate = new Promise((resolve) => { releaseDescriptor = resolve; });
  const { dom, log } = await setup([COMPONENT], {
    descriptorFetch: (url) =>
      url.endsWith("my-counter.json") ? descriptorGate : null,
  });

  const element = dom.window.document.createElement("my-counter");
  dom.window.document.body.appendChild(element);
  const ready = element._mochiReady;
  element.remove();
  await flushLifecycle();

  releaseDescriptor({
    ok: true,
    json: async () => ({ schema_version: 2, ...COMPONENT }),
  });
  await ready;
  await flushLifecycle();

  assert.equal(element._mochiMountState, "unmounted");
  assert.deepEqual(log.unmounts, []);
  assert.equal(log.components.size, 0);
  assert.equal(log.bindings.length, 0);

  dom.window.document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element._mochiMountState, "mounted");
  assert.equal(element._mochiInstance, "1");
  assert.equal(log.components.size, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 1);
});

test("a conditional child tag loads its descriptor and bytecode when the branch mounts", async () => {
  const parent = {
    tag_name: "screen-host",
    class_name: "ScreenHost",
    chi_file: "screen-host.chi",
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
          { html_template: "<my-counter></my-counter>", bindings: [], events: [] },
        ],
      },
    ],
    events: [],
  };

  const { loader, module, log } = await setup([parent, COMPONENT]);
  module.patchQueue.push({ patches: [{ id: 0, value: "false" }] });

  const host = document.createElement("screen-host");
  document.body.appendChild(host);
  await host._mochiReady;

  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 0);
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.chi")).length, 0);

  module.patchQueue.push({ patches: [{ id: 0, value: "true" }] });
  module.patchQueue.push({ patches: [{ id: 0, value: "4" }, { id: 1, value: "true" }] });
  loader.applyPatches(host, module);
  await flushLifecycle();

  const child = host.shadowRoot.querySelector("my-counter");
  assert.ok(child);
  await child._mochiReady;
  assert.equal(child.shadowRoot.querySelector(".count").textContent, "Count: 4");
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.chi")).length, 1);
  const loadsAfterFirstUse = log.loads.length;

  module.patchQueue.push({ patches: [{ id: 0, value: "false" }] });
  loader.applyPatches(host, module);
  await flushLifecycle();
  assert.equal(host.shadowRoot.querySelector("my-counter"), null);
  assert.equal(log.components.size, 1);

  module.patchQueue.push({ patches: [{ id: 0, value: "true" }] });
  module.patchQueue.push({ patches: [{ id: 0, value: "5" }, { id: 1, value: "true" }] });
  loader.applyPatches(host, module);
  await flushLifecycle();

  const reopened = host.shadowRoot.querySelector("my-counter");
  await reopened._mochiReady;
  assert.notEqual(reopened, child);
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.chi")).length, 1);
  assert.equal(log.loads.length, loadsAfterFirstUse);
});

test("shared style files load on first use once for concurrent components", async () => {
  const active = {
    ...COMPONENT,
    tag_name: "style-active",
    class_name: "StyleActive",
    chi_file: "style-active.chi",
    style_resources: ["css-active"],
  };
  const inactive = {
    ...COMPONENT,
    tag_name: "style-inactive",
    class_name: "StyleInactive",
    chi_file: "style-inactive.chi",
    style_resources: ["css-inactive"],
  };
  const resources = {
    "css-active": { kind: "style", file: "components/styles/active.css" },
    "css-inactive": { kind: "style", file: "components/styles/inactive.css" },
  };
  const { log } = await setup([active, inactive], {
    resources,
    resourceBodies: {
      "components/styles/active.css": ".active { color: red; }",
      "components/styles/inactive.css": ".inactive { color: blue; }",
    },
  });

  const first = document.createElement("style-active");
  document.body.appendChild(first);
  await first._mochiReady;

  assert.equal(log.fetches.filter((url) => url.endsWith("active.css")).length, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("inactive.css")).length, 0);

  const second = document.createElement("style-inactive");
  const third = document.createElement("style-inactive");
  document.body.appendChild(second);
  document.body.appendChild(third);
  await Promise.all([second._mochiReady, third._mochiReady]);

  assert.equal(log.fetches.filter((url) => url.endsWith("inactive.css")).length, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("style-inactive.json")).length, 1);
  assert.equal(log.fetches.filter((url) => url.endsWith("style-inactive.chi")).length, 1);
});

test("boot rejects a manifest schema the loader does not understand", async () => {
  const base = manifest([], undefined, undefined);
  await assert.rejects(
    setup([], { manifest: { ...base, schema_version: 3 } }),
    /unsupported manifest schema 3 .*loader supports schema 2/,
  );

  const { schema_version, ...missingVersion } = base;
  await assert.rejects(
    setup([], { manifest: missingVersion }),
    /unsupported manifest schema undefined/,
  );
});

test("a component package must exist in the manifest", async () => {
  const component = {
    ...COMPONENT,
    package: "component:missing-counter",
  };
  const { dom } = await setup([component]);

  const element = dom.window.document.createElement("my-counter");
  dom.window.document.body.appendChild(element);
  await assert.rejects(
    element._mochiReady,
    /missing package 'component:missing-counter'/,
  );
});

test("package dependency cycles fail before the component class runs", async () => {
  const component = {
    ...COMPONENT,
    package: "component:cycle-a",
  };
  const base = manifest([component], undefined, undefined);
  base.packages = {
    "component:cycle-a": {
      kind: "component",
      file: "components/my-counter.chi",
      dependencies: ["ruby:cycle-b"],
    },
    "ruby:cycle-b": {
      kind: "ruby",
      file: "components/cycle-b.chi",
      dependencies: ["component:cycle-a"],
    },
  };
  const { dom, log } = await setup([component], { manifest: base });

  const element = dom.window.document.createElement("my-counter");
  dom.window.document.body.appendChild(element);
  await assert.rejects(element._mochiReady, /package cycle at component:cycle-a/);
  assert.equal(log.loads.length, 0);
});

test("package dependencies load on first use once for concurrent instances", async () => {
  const component = { ...COMPONENT, package: "component:lazy-dependent" };
  const base = manifest([component], undefined, undefined);
  base.packages = {
    "component:lazy-dependent": {
      kind: "component",
      file: "components/my-counter.chi",
      dependencies: ["ruby:lazy-dep"],
    },
    "ruby:lazy-dep": {
      kind: "ruby",
      file: "components/ruby-lazy-dep.chi",
      dependencies: [],
    },
  };
  const { log } = await setup([component], { manifest: base });

  assert.equal(log.fetches.filter((url) => url.endsWith(".chi")).length, 0);

  const first = document.createElement("my-counter");
  const second = document.createElement("my-counter");
  document.body.append(first, second);
  await Promise.all([first._mochiReady, second._mochiReady]);

  const componentFetches = log.fetches.filter((url) => url.endsWith("my-counter.chi"));
  const dependencyFetches = log.fetches.filter((url) => url.endsWith("ruby-lazy-dep.chi"));
  assert.equal(componentFetches.length, 1);
  assert.equal(dependencyFetches.length, 1);
  assert.ok(log.fetches.indexOf(dependencyFetches[0]) < log.fetches.indexOf(componentFetches[0]));
  assert.equal(log.loads.length, 2);
});

test("formatting capability host is read from the versioned capabilities map", async () => {
  const component = { ...FORMAT_COMPONENT };
  const base = manifest([component], undefined, undefined);
  base.capabilities = {
    formatting: {
      version: 1,
      host: "mochi-format.js",
      operations: { format: "sync" },
      packages: [],
    },
  };
  base.packages = {
    "component:format-panel": {
      kind: "component",
      file: "components/format-panel.chi",
      dependencies: [],
    },
  };
  component.package = "component:format-panel";

  const adapter = formatAdapter();
  const { dom, log, module } = await setup([component], {
    manifest: base,
    hostModuleFactory: async (url) => {
      log.hostUrls.push(url);
      return adapter;
    },
  });

  const element = dom.window.document.createElement("format-panel");
  dom.window.document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(log.hostUrls.length, 1);
  assert.ok(log.hostUrls[0].endsWith("/mochi-format.js"));
  assert.equal(module.__mochiHostCapabilities.formatting, adapter);
});

test("shared style resources use one adopted sheet before the local override", async () => {
  const sharedCss = ":host { display: block; } .control { padding: 4px; }";
  const component = {
    ...COMPONENT,
    css: ".count { color: red; } .control { padding: 9px; }",
    style_resources: ["css-reset"],
  };
  const { dom } = await setup([component], {
    resources: { "css-reset": { kind: "style", text: sharedCss } },
  });
  const window = dom.window;
  class FakeStyleSheet {
    constructor() {
      this.cssText = "";
    }
    replaceSync(text) {
      this.cssText = text;
    }
  }
  global.CSSStyleSheet = window.CSSStyleSheet = FakeStyleSheet;
  Object.defineProperty(window.ShadowRoot.prototype, "adoptedStyleSheets", {
    configurable: true,
    get() { return this._mochiAdoptedSheets || []; },
    set(value) { this._mochiAdoptedSheets = value; },
  });

  const first = document.createElement("my-counter");
  const second = document.createElement("my-counter");
  document.body.appendChild(first);
  document.body.appendChild(second);
  await Promise.all([first._mochiReady, second._mochiReady]);

  assert.equal(first.shadowRoot.querySelectorAll("style").length, 0);
  assert.equal(first.shadowRoot.adoptedStyleSheets.length, 2);
  assert.equal(first.shadowRoot.adoptedStyleSheets[0].cssText, sharedCss);
  assert.equal(first.shadowRoot.adoptedStyleSheets[1].cssText, component.css);
  assert.equal(second.shadowRoot.adoptedStyleSheets[0], first.shadowRoot.adoptedStyleSheets[0]);
});

test("shared style resources fall back to ordered style elements", async () => {
  const sharedCss = ":host { display: block; } .control { padding: 4px; }";
  const component = {
    ...COMPONENT,
    css: ".control { padding: 9px; }",
    style_resources: ["css-reset"],
  };
  await setup([component], {
    resources: { "css-reset": { kind: "style", text: sharedCss } },
  });
  global.CSSStyleSheet = undefined;

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  const styles = element.shadowRoot.querySelectorAll("style");
  assert.equal(styles.length, 2);
  assert.equal(styles[0].getAttribute("data-mochi-style-resource"), "css-reset");
  assert.equal(styles[0].textContent, sharedCss);
  assert.equal(styles[1].textContent, component.css);
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

test("compiler binding target failures report authored context and clear partial DOM", async () => {
  const mismatch = {
    ...COMPONENT,
    tag_name: "mismatch-counter",
    class_name: "MismatchCounter",
    bindings: [
      {
        id: 7,
        path: [0, 99],
        kind: "attr",
        attr_name: "class",
        source: {
          file: "app/components/mismatch_counter.rb",
          line: 18,
          column: 9,
          end_line: 18,
          end_column: 24,
        },
      },
    ],
  };
  const { log } = await setup([mismatch]);
  const element = document.createElement("mismatch-counter");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady, (error) => {
    assert.match(error.message, /missing binding target at path \[0, 99\]/);
    assert.match(error.message, /mismatch-counter \(MismatchCounter\)/);
    assert.match(error.message, /binding 7, kind attr, attribute "class"/);
    assert.match(error.message, /app\/components\/mismatch_counter\.rb:18:9-18:24/);
    return true;
  });

  assert.equal(element._mochiMountState, "failed");
  assert.match(element.mochiError.message, /app\/components\/mismatch_counter\.rb:18:9-18:24/);
  assert.equal(element.shadowRoot.childNodes.length, 0);
  assert.deepEqual(element.bindingTargets, {});
  assert.deepEqual(element.bindingValues, {});
  assert.deepEqual(element.bindingData, {});
  assert.equal(log.components.size, 0);
  assert.deepEqual(log.bindings, []);
});

test("compiler binding target node type mismatches fail before VM registration", async () => {
  const mismatch = {
    ...COMPONENT,
    tag_name: "wrong-kind-counter",
    class_name: "WrongKindCounter",
    bindings: [{
      id: 8,
      path: [0, 0],
      kind: "attr",
      attr_name: "class",
      source: { file: "app/components/wrong_kind.rb", line: 6, column: 4 },
    }],
  };
  const { log } = await setup([mismatch]);
  const element = document.createElement("wrong-kind-counter");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady, (error) => {
    assert.match(error.message, /invalid attr binding target \(DOM node type 3\)/);
    assert.match(error.message, /wrong-kind-counter \(WrongKindCounter\), binding 8, kind attr, attribute "class"/);
    assert.match(error.message, /app\/components\/wrong_kind\.rb:6:4/);
    return true;
  });
  assert.equal(element.shadowRoot.childNodes.length, 0);
  assert.equal(log.components.size, 0);
  assert.deepEqual(log.bindings, []);
});

test("compiler binding placeholder validation rejects same-kind path mismatch and accepts literal braces", async () => {
  const { log } = await setup([{
    ...COMPONENT,
    tag_name: "placeholder-check",
    class_name: "PlaceholderCheck",
    html_template: '<span>{literal}</span><em>{@label}</em>',
    bindings: [{
      id: 12,
      // Valid text node, wrong target: must not silently leave the compiled
      // placeholder in the actual expression node.
      path: [0, 0],
      kind: "text",
      template_text: "{@label}",
      template_start: 0,
      template_end: 8,
      source: { file: "app/components/placeholder_check.rb", line: 11, column: 7 },
    }],
  }]);
  const element = document.createElement("placeholder-check");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady, (error) => {
    assert.match(error.message, /compiler placeholder "\{@label\}" is missing from its resolved target/);
    assert.match(error.message, /placeholder-check \(PlaceholderCheck\), binding 12, kind text/);
    assert.match(error.message, /app\/components\/placeholder_check\.rb:11:7/);
    return true;
  });
  assert.equal(element._mochiMountState, "failed");
  assert.equal(element.shadowRoot.childNodes.length, 0);
  assert.equal(log.components.size, 0);
  assert.deepEqual(log.bindings, []);

  const valid = {
    ...COMPONENT,
    tag_name: "literal-brace-check",
    class_name: "LiteralBraceCheck",
    html_template: '<span>{literal}</span><em>{@label}</em>',
    bindings: [{
      id: 13,
      path: [1, 0],
      kind: "text",
      template_text: "{@label}",
      template_start: 0,
      template_end: 8,
      getter_sym: "__mochi_bind_13",
    }],
  };
  const { log: validLog } = await setup([valid]);
  const validElement = document.createElement("literal-brace-check");
  document.body.appendChild(validElement);
  await validElement._mochiReady;
  assert.equal(validElement.shadowRoot.querySelector("span").textContent, "{literal}");
  assert.equal(validElement._mochiMountState, "mounted");
  assert.equal(validLog.components.size, 1);
});

test("failed mount reconnect reuses one delegated listener and installs bindings once", async () => {
  const { log } = await setup([COMPONENT]);
  const rootListeners = [];
  const originalAddEventListener = window.ShadowRoot.prototype.addEventListener;
  window.ShadowRoot.prototype.addEventListener = function (type, listener, options) {
    rootListeners.push(type);
    return originalAddEventListener.call(this, type, listener, options);
  };
  log.failBindingAt = 2;
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await assert.rejects(element._mochiReady);
  assert.equal(element.shadowRoot.childNodes.length, 0);

  element.remove();
  await flushLifecycle();
  log.failBindingAt = undefined;
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(element._mochiMountState, "mounted");
  assert.equal(log.components.size, 1);
  assert.equal(log.bindings.length, 2);
  assert.deepEqual(rootListeners, ["click", "change"]);
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

test("unmount releases the owner's timer and route and storage subscriptions", async () => {
  const { loader, module, log } = await setup([COMPONENT]);
  log.methods.add("on_route");
  log.methods.add("on_theme");
  log.requiredArgs.set("on_route", 1);
  log.requiredArgs.set("on_theme", 1);

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  const instance = String(element._mochiInstance);
  module.queueEmit([
    { __host: "timer", id: 731, kind: "every", ms: 60000, instance, callback: "increment" },
    { __host: "route_subscribe", instance },
    { __host: "storage_subscribe", key: "owned-theme", instance, callback: "on_theme" },
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  element._dispatchAction({ action: "increment" });

  assert.equal(loader.debugStats().timers, 1);
  assert.equal(loader.debugStats().routeSubscribers, 1);
  assert.equal(loader.debugStats().storageSubscribers, 1);
  assert.equal(loader.debugStats().storageSubscriptionKeys, 1);

  element.remove();
  await flushLifecycle();
  assert.equal(loader.debugStats().timers, 0);
  assert.equal(loader.debugStats().routeSubscribers, 0);
  assert.equal(loader.debugStats().storageSubscribers, 0);
  assert.equal(loader.debugStats().storageSubscriptionKeys, 0);
  assert.equal(loader.debugStats().unmountedInstances, 0);
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
    id: 1,
    instance: "1",
    url: "/api/late",
    callback: "increment",
    options: {},
  }));
  first._dispatchAction("increment");
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(log.fetches.some((url) => new URL(url, "http://localhost").pathname === "/api/late"));

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

    // Two records for one attribute coalesce to the final value and one flush.
    element.setAttribute("label", "two");
    element.setAttribute("label", "three");
    await flushLifecycle();

    assert.equal(log.ivarSets.length, setsAfterMount + 1);
    assert.deepEqual(log.ivarSets.at(-1), { instance: "1", name: "label", value: "three" });
    assert.equal(log.flushes.length, flushesAfterMount + 1);

    // Echoing the current value writes nothing and does not flush.
    element.setAttribute("label", "three");
    await flushLifecycle();
    assert.equal(log.ivarSets.length, setsAfterMount + 1);
    assert.equal(log.flushes.length, flushesAfterMount + 1);

    // Removal follows the documented string default: the prop becomes "".
    element.removeAttribute("label");
    await flushLifecycle();
    assert.deepEqual(log.ivarSets.at(-1), { instance: "1", name: "label", value: "" });
    assert.equal(log.flushes.length, flushesAfterMount + 2);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("one observer batch writes each changed attribute once and flushes once", async () => {
  const { dom, log } = await setup([COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const element = document.createElement("my-counter");
    document.body.appendChild(element);
    await element._mochiReady;
    const setsAfterMount = log.ivarSets.length;
    const flushesAfterMount = log.flushes.length;

    element.setAttribute("alpha", "1");
    element.setAttribute("beta", "2");
    element.setAttribute("alpha", "3");
    await flushLifecycle();

    assert.deepEqual(log.ivarSets.slice(setsAfterMount), [
      { instance: "1", name: "alpha", value: "3" },
      { instance: "1", name: "beta", value: "2" },
    ]);
    assert.equal(log.flushes.length, flushesAfterMount + 1);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("attribute setter failure reports component and prop context without flushing", async () => {
  const { dom, log } = await setup([COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;
  const details = [];
  document.addEventListener("mochi:error", (event) => details.push(event.detail));

  try {
    const element = document.createElement("my-counter");
    document.body.appendChild(element);
    await element._mochiReady;
    const flushesAfterMount = log.flushes.length;

    log.errorText = "state string capacity exceeded";
    log.failIvar = true;
    element.setAttribute("bad-prop", "boom");
    await flushLifecycle();

    assert.equal(details.length, 1);
    assert.equal(details[0].phase, "attribute");
    assert.equal(details[0].tagName, "my-counter");
    assert.equal(details[0].className, "MyCounter");
    assert.equal(details[0].attribute, "bad-prop");
    assert.equal(details[0].property, "bad_prop");
    assert.match(details[0].message, /attribute setter failed for "bad-prop"/);
    assert.match(details[0].vmText, /state string capacity exceeded/);
    assert.equal(element.mochiError.mochi.attribute, "bad-prop");
    assert.equal(log.flushes.length, flushesAfterMount);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a parent attribute patch updates the mounted child instance without remounting", async () => {
  const childComponent = {
    tag_name: "live-child",
    class_name: "LiveChild",
    chi_file: "live-child.chi",
    html_template: '<span class="child-label">{@label}</span>',
    css: "",
    bindings: [
      {
        id: 0,
        path: [0, 0],
        kind: "text",
        attr_name: null,
        template_text: "{@label}",
        getter_sym: "__mochi_bind_0",
      },
    ],
    events: [],
  };
  const parentComponent = {
    tag_name: "live-parent",
    class_name: "LiveParent",
    chi_file: "live-parent.chi",
    html_template:
      '<span class="parent-label">{@label}</span><live-child label="boot"></live-child>',
    css: "",
    bindings: [
      {
        id: 0,
        path: [0, 0],
        kind: "text",
        attr_name: null,
        template_text: "{@label}",
        getter_sym: "__mochi_bind_0",
      },
      {
        id: 1,
        path: [1],
        kind: "attr",
        attr_name: "label",
        attr_kind: "text",
        template_text: "{@label}",
        getter_sym: "__mochi_bind_1",
      },
    ],
    events: [],
  };

  const { dom, log, module, loader } = await setup([parentComponent, childComponent]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const parent = document.createElement("live-parent");
    document.body.appendChild(parent);
    await parent._mochiReady;
    const child = parent.shadowRoot.querySelector("live-child");
    assert.ok(child);
    await child._mochiReady;

    const childInstance = child._mochiInstance;
    const childText = child.shadowRoot.querySelector(".child-label");
    const flushesBefore = log.flushes.length;
    const dispatchedBefore = log.dispatched.length;

    module.patchQueue.push({ patches: [{ id: 1, value: "alpha" }] });
    module.patchQueue.push({ patches: [{ id: 0, value: "alpha" }] });
    loader.applyPatches(parent, module);
    await flushLifecycle();

    assert.equal(child.getAttribute("label"), "alpha");
    assert.deepEqual(log.ivarSets.at(-1), { instance: childInstance, name: "label", value: "alpha" });
    assert.equal(childText.textContent, "alpha");
    assert.equal(child.shadowRoot.querySelector(".child-label"), childText);
    assert.equal(child._mochiInstance, childInstance);
    assert.equal(log.flushes.length, flushesBefore + 2);

    module.patchQueue.push({ patches: [{ id: 1, value: "beta" }] });
    module.patchQueue.push({ patches: [{ id: 0, value: "beta" }] });
    loader.applyPatches(parent, module);
    await flushLifecycle();

    assert.equal(childText.textContent, "beta");
    assert.equal(child.shadowRoot.querySelector(".child-label"), childText);
    assert.equal(child._mochiInstance, childInstance);

    // Removing the attribute writes the documented empty-string prop and
    // leaves the mounted instance and its node in place.
    module.patchQueue.push({ patches: [{ id: 1, value: NIL }] });
    module.patchQueue.push({ patches: [{ id: 0, value: "" }] });
    loader.applyPatches(parent, module);
    await flushLifecycle();

    assert.equal(child.hasAttribute("label"), false);
    assert.deepEqual(log.ivarSets.at(-1), { instance: childInstance, name: "label", value: "" });
    assert.equal(childText.textContent, "");
    assert.equal(child._mochiInstance, childInstance);
    assert.equal(log.dispatched.length, dispatchedBefore);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("declared props mount as typed values and keep false, zero, and empty distinct", async () => {
  const { log } = await setup([TYPED_COMPONENT]);
  const element = document.createElement("typed-badge");
  element.setAttribute("label", "");
  element.setAttribute("count", "0");
  element.setAttribute("flag", "false");
  element.setAttribute("rows", '[{"id":1}]');
  element.setAttribute("meta", '{"currency":"USD"}');
  document.body.appendChild(element);
  await element._mochiReady;

  assert.deepEqual(log.mountProps, [{
    label: "",
    count: 0,
    flag: false,
    rows: [{ id: 1 }],
    meta: { currency: "USD" },
  }]);
  // Declared props never take the string-ivar path.
  assert.deepEqual(log.ivarSets, []);
  assert.deepEqual(log.propSets, []);
});

test("wide integers and floats use exact typed transport", async () => {
  const { dom, log } = await setup([TYPED_COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const element = document.createElement("typed-badge");
    element.setAttribute("count", "9007199254740993");
    element.setAttribute("ratio", "0.25");
    document.body.appendChild(element);
    await element._mochiReady;
    assert.deepEqual(log.mountProps[0], {
      count: { __mochi_number: "i64", value: "9007199254740993" },
      ratio: { __mochi_number: "f64", value: "0.25" },
    });

    element.setAttribute("count", "9007199254740995");
    element.setAttribute("ratio", "0.75");
    await flushLifecycle();
    assert.deepEqual(log.propSets.at(-1).props, {
      count: { __mochi_number: "i64", value: "9007199254740995" },
      ratio: { __mochi_number: "f64", value: "0.75" },
    });
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a string prop keeps JSON text and defers parent placeholders", async () => {
  const { dom, log } = await setup([TYPED_COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const literal = document.createElement("typed-badge");
    literal.setAttribute("label", '{"a":1}');
    document.body.appendChild(literal);
    await literal._mochiReady;
    assert.equal(log.mountProps[0].label, '{"a":1}');

    const deferred = document.createElement("typed-badge");
    deferred.setAttribute("label", "{parent_label}");
    document.body.appendChild(deferred);
    await deferred._mochiReady;
    assert.deepEqual(log.mountProps[1], {});

    deferred.setAttribute("label", "resolved");
    await flushLifecycle();
    assert.deepEqual(log.propSets.at(-1), {
      instance: "2",
      props: { label: "resolved" },
    });
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("missing required prop fails before any instance is mounted", async () => {
  const required = {
    ...TYPED_COMPONENT,
    props: [
      { name: "label", type: "string", required: true, source: { file: "lib/required.rb", line: 4 } },
    ],
  };
  const { log } = await setup([required]);
  const details = [];
  document.addEventListener("mochi:error", (event) => details.push(event.detail));

  const element = document.createElement("typed-badge");
  document.body.appendChild(element);
  await assert.rejects(element._mochiReady);

  assert.equal(log.components.size, 0);
  assert.deepEqual(log.mountProps, []);
  assert.equal(details.length, 1);
  assert.equal(details[0].phase, "mount");
  assert.equal(details[0].tagName, "typed-badge");
  assert.equal(details[0].property, "label");
  assert.match(details[0].message, /prop "label" is required/);
  assert.match(details[0].source, /lib\/required\.rb:4/);
});

test("typed prop updates are installed in one batch and flushed once", async () => {
  const { dom, log } = await setup([TYPED_COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;

  try {
    const element = document.createElement("typed-badge");
    element.setAttribute("label", "one");
    element.setAttribute("count", "1");
    document.body.appendChild(element);
    await element._mochiReady;
    const setsAfterMount = log.propSets.length;
    const flushesAfterMount = log.flushes.length;

    element.setAttribute("label", "two");
    element.setAttribute("count", "2");
    await flushLifecycle();

    assert.equal(log.propSets.length, setsAfterMount + 1);
    assert.deepEqual(log.propSets.at(-1), {
      instance: "1",
      props: { label: "two", count: 2 },
    });
    assert.equal(log.flushes.length, flushesAfterMount + 1);
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a typed prop child disposes and remounts with a fresh instance", async () => {
  const { log } = await setup([TYPED_COMPONENT]);

  const element = document.createElement("typed-badge");
  element.setAttribute("label", "before");
  document.body.appendChild(element);
  await element._mochiReady;
  assert.deepEqual(log.mountProps[0], { label: "before" });

  element.remove();
  await flushLifecycle();
  assert.deepEqual(log.unmounts, ["1"]);
  assert.equal(log.components.size, 0);

  const replacement = document.createElement("typed-badge");
  replacement.setAttribute("label", "after");
  document.body.appendChild(replacement);
  await replacement._mochiReady;
  assert.deepEqual(log.mountProps[1], { label: "after" });
  assert.notEqual(replacement._mochiInstance, element._mochiInstance);
});

test("invalid and removed declared props report source and send null on removal", async () => {
  const { dom, log } = await setup([TYPED_COMPONENT]);
  const previousObserver = global.MutationObserver;
  global.MutationObserver = dom.window.MutationObserver;
  const details = [];
  document.addEventListener("mochi:error", (event) => details.push(event.detail));

  try {
    const element = document.createElement("typed-badge");
    element.setAttribute("label", "one");
    element.setAttribute("note", "hello");
    element.setAttribute("count", "1");
    document.body.appendChild(element);
    await element._mochiReady;

    const setsAfterMount = log.propSets.length;
    element.setAttribute("count", "many");
    await flushLifecycle();
    assert.equal(log.propSets.length, setsAfterMount);
    assert.equal(details.length, 1);
    assert.equal(details[0].property, "count");
    assert.match(details[0].message, /expects an integer/);
    assert.match(details[0].source, /lib\/badge\.rb:8/);

    element.removeAttribute("note");
    await flushLifecycle();
    assert.equal(log.propSets.length, setsAfterMount + 1);
    assert.deepEqual(log.propSets.at(-1), {
      instance: "1",
      props: { note: null },
    });
  } finally {
    if (previousObserver === undefined) {
      delete global.MutationObserver;
    } else {
      global.MutationObserver = previousObserver;
    }
  }
});

test("a fresh mount replaces its attribute observer without stacking", async () => {
  const { dom, log } = await setup([COMPONENT]);
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

    // A disposed instance is no longer observed: later attribute writes are
    // not forwarded to the VM.
    const setsAfterDispose = log.ivarSets.length;
    element.setAttribute("label", "ignored");
    await flushLifecycle();
    assert.equal(log.ivarSets.length, setsAfterDispose);
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

test("child events route to their exact parent instance with typed payloads", async () => {
  const { module, log } = await setup([EVENT_PARENT_COMPONENT, EMITTER_COMPONENT]);
  log.methods.add("choose");
  log.methods.add("choose_bad");
  log.methods.add("row_selected");
  log.methods.add("refresh");
  log.requiredArgs.set("row_selected", 1);

  const parents = [document.createElement("event-parent"), document.createElement("event-parent")];
  parents.forEach((parent) => document.body.appendChild(parent));
  await Promise.all(parents.map((parent) => parent._mochiReady));
  const children = parents.map((parent) => parent.shadowRoot.querySelector("event-emitter"));
  await Promise.all(children.map((child) => child._mochiReady));

  let actionEvents = 0;
  let escapedSelects = 0;
  document.addEventListener("mochi:action", () => { actionEvents += 1; });
  document.body.addEventListener("select", () => { escapedSelects += 1; });
  log.onDispatch = (name, instance) => {
    if (name !== "choose") return;
    module.queueEmit(JSON.stringify({
      __child_event: "select",
      instance,
      payload: {
        id: Number(instance),
        label: "row-" + instance,
        active: true,
        tags: ["a", "b"],
        meta: { currency: "USD" },
      },
    }) + "\n");
  };

  const payloadFor = (instance) => ({
    id: Number(instance),
    label: "row-" + instance,
    active: true,
    tags: ["a", "b"],
    meta: { currency: "USD" },
  });

  children[0].shadowRoot.querySelector("button.choose").click();
  await new Promise((resolve) => setImmediate(resolve));

  const selectSymbol = log.symbols.get("row_selected");
  assert.ok(selectSymbol);
  assert.deepEqual(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol),
    [{ instance: parents[0]._mochiInstance, methodSymbol: selectSymbol, args: [payloadFor(children[0]._mochiInstance)] }],
  );

  children[1].shadowRoot.querySelector("button.choose").click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol),
    [
      { instance: parents[0]._mochiInstance, methodSymbol: selectSymbol, args: [payloadFor(children[0]._mochiInstance)] },
      { instance: parents[1]._mochiInstance, methodSymbol: selectSymbol, args: [payloadFor(children[1]._mochiInstance)] },
    ],
  );
  // A scoped child event is not a document-wide action broadcast, and it does
  // not escape the connected parent's shadow tree.
  assert.equal(actionEvents, 0);
  assert.equal(escapedSelects, 0);
});

test("invalid child event payloads report the declared contract and stop delivery", async () => {
  const { module, log } = await setup([EVENT_PARENT_COMPONENT, EMITTER_COMPONENT]);
  log.methods.add("choose");
  log.methods.add("choose_bad");
  log.methods.add("row_selected");
  log.methods.add("refresh");
  log.requiredArgs.set("row_selected", 1);

  const parent = document.createElement("event-parent");
  document.body.appendChild(parent);
  await parent._mochiReady;
  const child = parent.shadowRoot.querySelector("event-emitter");
  await child._mochiReady;

  const details = [];
  document.addEventListener("mochi:error", (event) => details.push(event.detail));
  const instance = child._mochiInstance;
  const base = { id: 1, label: "row", active: true, tags: [], meta: {} };
  const invalidPayloads = [
    { label: "row", active: true, tags: [], meta: {} },
    { ...base, extra: true },
    { ...base, id: "not-an-integer" },
    { ...base, id: { __mochi_number: "i64", value: "9223372036854775808" } },
  ];
  module.queueEmit(invalidPayloads.map((payload) => JSON.stringify({
    __child_event: "select",
    instance,
    payload,
  })).join("\n") + "\n");

  const selectSymbol = log.symbols.get("row_selected");
  const before = log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol).length;
  parent.shadowRoot.querySelector("button.refresh").click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(details.length, 4);
  assert.equal(details[0].phase, "event");
  assert.equal(details[0].tagName, "event-emitter");
  assert.equal(details[0].event, "select");
  assert.equal(details[0].payloadKey, "id");
  assert.match(details[0].message, /requires payload field "id"/);
  assert.match(details[1].message, /does not declare payload field "extra"/);
  assert.equal(details[1].payloadKey, undefined);
  assert.equal(details[2].payloadKey, "id");
  assert.equal(details[2].eventType, "integer");
  assert.match(details[2].message, /expects integer, got string/);
  assert.match(details[3].message, /invalid or out-of-range i64/);
  details.forEach((detail) => {
    assert.match(detail.source, /lib\/event_row\.rb:3/);
  });
  assert.equal(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol).length,
    before,
  );
});

test("a stale child event cannot reach a replacement instance", async () => {
  const { module, log } = await setup([EVENT_PARENT_COMPONENT, EMITTER_COMPONENT]);
  log.methods.add("choose");
  log.methods.add("choose_bad");
  log.methods.add("row_selected");
  log.methods.add("refresh");
  log.requiredArgs.set("row_selected", 1);

  const parent = document.createElement("event-parent");
  document.body.appendChild(parent);
  await parent._mochiReady;
  const oldChild = parent.shadowRoot.querySelector("event-emitter");
  await oldChild._mochiReady;
  const oldInstance = oldChild._mochiInstance;

  oldChild.remove();
  await flushLifecycle();

  const replacement = document.createElement("event-emitter");
  replacement.setAttribute("data-mochi-select", "row_selected");
  parent.shadowRoot.querySelector(".wrap").appendChild(replacement);
  await replacement._mochiReady;
  assert.notEqual(replacement._mochiInstance, oldInstance);

  module.queueEmit(JSON.stringify({
    __child_event: "select",
    instance: oldInstance,
    payload: {
      id: 99,
      label: "stale",
      active: false,
      tags: [],
      meta: {},
    },
  }) + "\n");

  const selectSymbol = log.symbols.get("row_selected");
  const before = log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol).length;
  parent.shadowRoot.querySelector("button.refresh").click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(
    log.dispatchedArgs.filter((entry) => entry.methodSymbol === selectSymbol).length,
    before,
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

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/api/logs");
  assert.equal(calls[0].init.method, "GET");
  assert.ok(calls[0].init.signal instanceof AbortSignal);
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

test("fetch converts Ruby Hash request bodies to JSON without losing headers", async () => {
  const calls = [];
  const { module } = await setup([COMPONENT], {
    fetch: async (url, init) => {
      calls.push({ url, init });
      return {
        status: 200,
        ok: true,
        headers: { get: () => "application/json" },
        text: async () => "{}"
      };
    }
  });

  module.queueFetch(JSON.stringify({
    id: 1,
    instance: "1",
    url: "/api/logs",
    callback: "on_logs",
    options: {
      method: "POST",
      headers: { "x-request-source": "logs" },
      body: { token: 7, query: "timeout & retry" }
    }
  }) + "\n");

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.body, '{"token":7,"query":"timeout & retry"}');
  assert.deepEqual(calls[0].init.headers, {
    "x-request-source": "logs",
    "content-type": "application/json"
  });
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

test("oversized fetch responses become a recoverable capacity envelope", async () => {
  const { module, log } = await setup([COMPONENT], {
    fetch: async () => ({
      status: 200,
      ok: true,
      headers: { get: () => "application/json" },
      text: async () => JSON.stringify({ payload: "x".repeat(20_000) }),
    }),
  });
  module.queueFetch(JSON.stringify({
    id: 1, instance: "1", url: "/api/large", callback: "on_logs", options: {}
  }) + "\n");
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(log.deliveredFetches[0].envelope, {
    status: 0, ok: false, body: "", data: null, error: "fetch response too large"
  });
  assert.equal(element.mochiError, undefined);
});

test("fetch callback failures are reported separately from response errors", async () => {
  const { module, log } = await setup([COMPONENT], {
    fetch: async () => ({ status: 200, ok: true, text: async () => "ok" }),
  });
  log.failFetchDelivery = true;
  module.queueFetch(JSON.stringify({
    id: 1, instance: "1", url: "/api/callback-failure", callback: "on_logs", options: {}
  }) + "\n");
  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(element.mochiError);
  assert.match(element.mochiError.message, /fetch callback failed for on_logs/);
  assert.doesNotMatch(element.mochiError.message, /HTTP 200|fetch response too large/);
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
  assert.equal(log.fetches.filter((url) => url.endsWith("my-counter.json")).length, 1);
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
  const styleCount = element.shadowRoot.adoptedStyleSheets
    ? element.shadowRoot.adoptedStyleSheets.length
    : element.shadowRoot.querySelectorAll("style").length;
  assert.equal(styleCount, 1);
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

test("boolean attributes toggle presence while textual attributes keep false, zero, and empty", async () => {
  const attrSemantics = {
    tag_name: "attr-semantics-check",
    class_name: "AttrSemanticsCheck",
    chi_file: "attr-semantics-check.chi",
    html_template:
      '<button class="action" disabled="{@disabled}" aria-expanded="{@expanded}">Go</button>' +
      '<span class="count" data-count="{@count}"></span>' +
      '<span class="note" title="{@note}"></span>' +
      '<p data-role="classes" class="box {first} {second}">x</p>',
    css: "",
    bindings: [
      { id: 0, path: [0], kind: "attr", attr_name: "disabled", attr_kind: "boolean", template_text: "{@disabled}", getter_sym: "__mochi_bind_0" },
      { id: 1, path: [0], kind: "attr", attr_name: "aria-expanded", attr_kind: "text", template_text: "{@expanded}", getter_sym: "__mochi_bind_1" },
      { id: 2, path: [1], kind: "attr", attr_name: "data-count", attr_kind: "text", template_text: "{@count}", getter_sym: "__mochi_bind_2" },
      { id: 3, path: [2], kind: "attr", attr_name: "title", attr_kind: "text", template_text: "{@note}", getter_sym: "__mochi_bind_3" },
      { id: 4, path: [3], kind: "attr", attr_name: "class", attr_kind: "text", template_text: "box {first} {second}", getter_sym: "__mochi_bind_4" },
      { id: 5, path: [3], kind: "attr", attr_name: "class", attr_kind: "text", template_text: "box {first} {second}", getter_sym: "__mochi_bind_5" },
    ],
    events: [],
  };

  const { loader, module } = await setup([attrSemantics]);
  module.patchQueue.push({
    patches: [
      { id: 0, value: "false" },
      { id: 1, value: "false" },
      { id: 2, value: "0" },
      { id: 3, value: "" },
      { id: 4, value: "one" },
      { id: 5, value: "two" },
    ],
  });

  const element = document.createElement("attr-semantics-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const button = element.shadowRoot.querySelector("button.action");
  const count = element.shadowRoot.querySelector(".count");
  const note = element.shadowRoot.querySelector(".note");
  const classes = element.shadowRoot.querySelector("[data-role='classes']");

  assert.equal(button.hasAttribute("disabled"), false);
  assert.equal(button.getAttribute("aria-expanded"), "false");
  assert.equal(count.getAttribute("data-count"), "0");
  assert.equal(note.getAttribute("title"), "");
  assert.equal(classes.getAttribute("class"), "box one two");

  module.patchQueue.push({ patches: [{ id: 0, value: "true" }, { id: 1, value: "true" }] });
  loader.applyPatches(element);
  assert.equal(button.getAttribute("disabled"), "true");
  assert.equal(button.getAttribute("aria-expanded"), "true");

  module.patchQueue.push({ patches: [{ id: 0, value: "" }, { id: 1, value: "" }] });
  loader.applyPatches(element);
  assert.equal(button.hasAttribute("disabled"), false);
  assert.equal(button.getAttribute("aria-expanded"), "");

  // Each fragment updates from its own cached value; the static `box` prefix
  // and the other fragment survive.
  module.patchQueue.push({ patches: [{ id: 4, value: "" }] });
  loader.applyPatches(element);
  assert.equal(classes.getAttribute("class"), "box  two");
  assert.equal(classes.classList.contains("box"), true);
  assert.equal(classes.classList.contains("one"), false);

  module.patchQueue.push({ patches: [{ id: 5, value: "TWO" }] });
  loader.applyPatches(element);
  assert.equal(classes.getAttribute("class"), "box  TWO");
  assert.equal(classes.classList.contains("two"), false);

  module.patchQueue.push({ patches: [{ id: 3, value: NIL }] });
  loader.applyPatches(element);
  assert.equal(note.hasAttribute("title"), false);
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
  // An intentional empty textual value stays present and empty.
  assert.equal(element.shadowRoot.querySelector(".nested").getAttribute("title"), "");

  module.patchQueue.push({ patches: [{ id: 1, value: NIL }] });
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
  assert.equal(link.getAttribute("href"), "");
  assert.equal(attrElement.bindingTargets[0], link);

  module.patchQueue.push({ patches: [{ id: 0, value: NIL }] });
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

test("row attributes distinguish boolean presence from textual false, zero, empty, and nil", async () => {
  const rowAttrComponent = {
    tag_name: "row-attr-check",
    class_name: "RowAttrCheck",
    chi_file: "row-attr-check.chi",
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
          template: '<li hidden="\uE0021\uE003" aria-expanded="\uE0022\uE003" data-count="\uE0023\uE003" title="\uE0024\uE003"></li>',
          bindings: [
            { slot: 1, kind: "attr", attr_name: "hidden", attr_kind: "boolean" },
            { slot: 2, kind: "attr", attr_name: "aria-expanded", attr_kind: "text" },
            { slot: 3, kind: "attr", attr_name: "data-count", attr_kind: "text" },
            { slot: 4, kind: "attr", attr_name: "title", attr_kind: "text" },
          ],
          children: [],
        },
      },
    ],
    events: [],
  };

  const { module, loader } = await setup([rowAttrComponent]);
  const item = { id: "a" };
  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[item, [null, false, "false", 0, ""]]]),
    }],
  });

  const element = document.createElement("row-attr-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const row = element.shadowRoot.querySelector("li");
  assert.equal(row.hasAttribute("hidden"), false);
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.equal(row.getAttribute("data-count"), "0");
  assert.equal(row.getAttribute("title"), "");

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[item, [null, true, "true", 0, null]]]),
    }],
  });
  loader.applyPatches(element);
  assert.equal(row.getAttribute("hidden"), "true");
  assert.equal(row.getAttribute("aria-expanded"), "true");
  assert.equal(row.hasAttribute("title"), false);

  module.patchQueue.push({
    patches: [{
      id: 0,
      value: JSON.stringify([[item, [null, "", "false", 0, ""]]]),
    }],
  });
  loader.applyPatches(element);
  assert.equal(row.hasAttribute("hidden"), false);
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.equal(row.getAttribute("title"), "");
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
    { kind: "literal", literal_type: "number", value: "9007199254740993" },
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
    args: [
      "tr_9f2a",
      1,
      { __mochi_number: "i64", value: "9007199254740993" },
    ],
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
  input.dispatchEvent(new global.Event("input", { bubbles: true, composed: true }));
  await new Promise((resolve) => setImmediate(resolve));

  const searchSymbol = log.symbols.get("on_search");
  assert.ok(searchSymbol);
  const payload = log.dispatchedArgs.at(-1).args[0];
  assert.deepEqual(payload, {
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
    target_ref: "",
    target_tag: "input",
    current_target_id: "",
    current_target_ref: "",
    current_target_tag: "input",
    target: { tag: "input", id: "", ref: "", component: "" },
    current_target: { tag: "input", id: "", ref: "", component: "" },
    composed_path: payload.composed_path,
    dataset: {},
  });
  assert.equal(payload.composed_path[0].tag, "input");
  assert.ok(payload.composed_path.some((node) => node.tag === "event-auto-check"));
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

test("synchronous modifiers prevent defaults and stop propagation before Ruby work", async () => {
  const modifierComponent = {
    tag_name: "event-modifier-check",
    class_name: "EventModifierCheck",
    chi_file: "event-modifier-check.chi",
    html_template:
      '<a class="link" href="#blocked" data-mochi-click="link" data-mochi-modifiers-click="prevent,stop">' +
      '<span class="inner">Link</span></a>' +
      '<button class="self" data-mochi-click="self_click" data-mochi-modifiers-click="self">' +
      '<span class="self-inner">Self</span></button>' +
      '<button class="plain" data-mochi-click="plain">Plain</button>',
    css: "",
    bindings: [],
    events: [
      { path: [0], event: "click", method_sym: "link", args: [], modifiers: ["prevent", "stop"] },
      { path: [1], event: "click", method_sym: "self_click", args: [], modifiers: ["self"] },
      { path: [2], event: "click", method_sym: "plain", args: [] },
    ],
  };

  const { dom, log } = await setup([modifierComponent]);
  log.methods.add("link");
  log.methods.add("self_click");
  log.methods.add("plain");
  const element = document.createElement("event-modifier-check");
  document.body.appendChild(element);
  await element._mochiReady;

  let documentClicks = 0;
  document.addEventListener("click", () => { documentClicks += 1; });

  const link = element.shadowRoot.querySelector(".link");
  const linkEvent = new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    composed: true,
  });
  link.dispatchEvent(linkEvent);

  assert.equal(linkEvent.defaultPrevented, true);
  assert.equal(documentClicks, 0);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(log.dispatched.filter((entry) => entry.methodSymbol === log.symbols.get("link")).length, 1);

  const nonCancelable = new dom.window.Event("click", {
    bubbles: true,
    cancelable: false,
    composed: true,
  });
  link.dispatchEvent(nonCancelable);
  assert.equal(nonCancelable.defaultPrevented, false);
  assert.equal(documentClicks, 0);
  await new Promise((resolve) => setImmediate(resolve));

  const selfButton = element.shadowRoot.querySelector(".self");
  selfButton.querySelector(".self-inner").dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    composed: true,
  }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(log.dispatched.filter(
    (entry) => entry.methodSymbol === log.symbols.get("self_click")).length, 0);
  assert.equal(documentClicks, 1);

  element.shadowRoot.querySelector(".plain").dispatchEvent(new dom.window.MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    composed: true,
  }));
  assert.equal(documentClicks, 2);
});

test("named refs move and restore focus with keyboard containment", async () => {
  const focusComponent = {
    tag_name: "focus-check",
    class_name: "FocusCheck",
    chi_file: "focus-check.chi",
    html_template:
      '<button class="opener" data-mochi-click="open">Open</button>' +
      '<div class="panel" data-mochi-focus-trap>' +
      '<button ref="first" class="first" data-mochi-click="close">First</button>' +
      '<button ref="last" class="last" data-mochi-click="close">Last</button>' +
      "</div>",
    css: "",
    bindings: [],
    events: [
      { path: [0], event: "click", method_sym: "open", args: [] },
      { path: [1, 0], event: "click", method_sym: "close", args: [] },
      { path: [1, 1], event: "click", method_sym: "close", args: [] },
    ],
  };

  const { dom, module, log } = await setup([focusComponent]);
  log.methods.add("open");
  log.methods.add("close");
  const element = document.createElement("focus-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const deepActive = () => {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) {
      active = active.shadowRoot.activeElement;
    }
    return active;
  };
  const opener = element.shadowRoot.querySelector(".opener");
  const first = element.shadowRoot.querySelector(".first");
  const last = element.shadowRoot.querySelector(".last");

  log.onDispatch = (name, instance) => {
    if (name === "open") {
      module.queueEmit(JSON.stringify({ __host: "focus", name: "first", instance }) + "\n");
    } else if (name === "close") {
      module.queueEmit(JSON.stringify({ __host: "restore_focus", instance }) + "\n");
    }
  };

  opener.focus();
  opener.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(deepActive(), first);

  const shiftTab = new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    shiftKey: true,
    bubbles: true,
    cancelable: true,
    composed: true,
  });
  first.dispatchEvent(shiftTab);
  assert.equal(shiftTab.defaultPrevented, true);
  assert.equal(deepActive(), last);

  const tab = new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    bubbles: true,
    cancelable: true,
    composed: true,
  });
  last.dispatchEvent(tab);
  assert.equal(tab.defaultPrevented, true);
  assert.equal(deepActive(), first);

  last.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(deepActive(), opener);
});

test("an unknown named ref reports a focus error", async () => {
  const focusErrorComponent = {
    tag_name: "focus-error-check",
    class_name: "FocusErrorCheck",
    chi_file: "focus-error-check.chi",
    html_template: '<button class="open" data-mochi-click="open">Open</button>',
    css: "",
    bindings: [],
    events: [{ path: [0], event: "click", method_sym: "open", args: [] }],
  };

  const { module, log } = await setup([focusErrorComponent]);
  log.methods.add("open");
  const element = document.createElement("focus-error-check");
  document.body.appendChild(element);
  await element._mochiReady;

  const errors = [];
  document.addEventListener("mochi:error", (event) => errors.push(event.detail));
  log.onDispatch = (name, instance) => {
    if (name === "open") {
      module.queueEmit(JSON.stringify({ __host: "focus", name: "missing", instance }) + "\n");
    }
  };

  element.shadowRoot.querySelector(".open").click();
  await new Promise((resolve) => setImmediate(resolve));

  const error = errors.find((candidate) => candidate.phase === "focus");
  assert.ok(error);
  assert.equal(error.reference, "missing");
  assert.match(error.message, /no element with ref "missing"/);
});

test("bind:value dispatches the event payload and reflects programmatic updates", async () => {
  const bindComponent = {
    tag_name: "bind-value-check",
    class_name: "BindValueCheck",
    chi_file: "bind-value-check.chi",
    html_template:
      '<input class="query" data-mochi-input="__mochi_set_query" value="{@query}">' +
      '<p class="label">{@label}</p>',
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
      {
        id: 1,
        path: [1, 0],
        kind: "text",
        attr_name: null,
        template_text: "{@label}",
        getter_sym: "__mochi_bind_1",
        getter_expr: "@label",
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
      target_ref: "",
      target_tag: "input",
      current_target_id: "",
      current_target_ref: "",
      current_target_tag: "input",
      target: { tag: "input", id: "", ref: "", component: "" },
      current_target: { tag: "input", id: "", ref: "", component: "" },
      composed_path: [{ tag: "input", id: "", ref: "", component: "" }],
      dataset: {},
    }],
  });

  input.setSelectionRange(1, 3);
  module.patchQueue.push({ patches: [{ id: 1, value: "changed" }] });
  loader.applyPatches(element);
  assert.equal(element.bindingTargets[0], input);
  assert.equal(input.value, "typed");
  assert.equal(input.selectionStart, 1);
  assert.equal(input.selectionEnd, 3);

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
  assert.equal(element.bindingTargets[0], input);
});

const FORMAT_COMPONENT = {
  tag_name: "format-panel",
  class_name: "FormatPanel",
  chi_file: "format-panel.chi",
  html_template: '<p class="value">format</p>',
  css: "",
  bindings: [],
  events: [],
  formatting: true,
  capabilities: ["formatting"],
};

function formatAdapter(format) {
  return {
    name: "formatting",
    version: 1,
    sync: { format: format || (() => "1") },
  };
}

test("formatting components register the optional adapter before mounting", async () => {
  const adapter = formatAdapter();
  const { module, log } = await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async (url) => {
      log.hostUrls.push(url);
      return adapter;
    },
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(log.hostUrls.length, 1);
  assert.ok(log.hostUrls[0].endsWith("/mochi-format.js"));
  assert.equal(module.__mochiHostCapabilities.formatting, adapter);
  assert.equal(module.__mochiHostCapabilities.formatting.sync.format(), "1");
});

test("adapter scripts can register through the loader registrar", async () => {
  const adapter = formatAdapter();
  const { module } = await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => {
      global.MochiHostAdapter.register(adapter);
    },
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(module.__mochiHostCapabilities.formatting, adapter);
  assert.ok(Object.isFrozen(adapter));
  assert.ok(Object.isFrozen(adapter.sync));
});

test("concurrent formatting components share one host request", async () => {
  let calls = 0;
  const adapter = formatAdapter();
  const { module } = await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => {
      calls += 1;
      return adapter;
    },
  });

  const first = document.createElement("format-panel");
  const second = document.createElement("format-panel");
  document.body.append(first, second);
  await Promise.all([first._mochiReady, second._mochiReady]);

  assert.equal(calls, 1);
  assert.equal(module.__mochiHostCapabilities.formatting, adapter);
});

test("components without formatting never request the optional adapter", async () => {
  const { module, log } = await setup([COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async (url) => {
      log.hostUrls.push(url);
      return formatAdapter();
    },
  });

  const element = document.createElement("my-counter");
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(log.hostUrls.length, 0);
  assert.equal(module.__mochiHostCapabilities, undefined);
});

test("host adapter failure names the capability and component", async () => {
  await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => {
      throw new Error("network down");
    },
  });

  const failures = [];
  document.addEventListener("mochi:error", (event) => failures.push(event.detail));
  const element = document.createElement("format-panel");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady,
    /host capability 'formatting' .*mochi-format\.js.*format-panel.*network down/);
  assert.equal(failures.length, 1);
  assert.equal(failures[0].phase, "capability");
  assert.match(failures[0].message, /mochi-format\.js/);
});

test("a failed host adapter load is evicted and can be retried", async () => {
  let attempts = 0;
  const adapter = formatAdapter();
  const { module } = await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("network down");
      return adapter;
    },
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);
  await assert.rejects(element._mochiReady, /host capability 'formatting'.*network down/);

  element.remove();
  await flushLifecycle();
  document.body.appendChild(element);
  await element._mochiReady;

  assert.equal(attempts, 2);
  assert.equal(element._mochiMountState, "mounted");
  assert.equal(module.__mochiHostCapabilities.formatting, adapter);
});

test("a host adapter must register the declared capability before mount", async () => {
  await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => {},
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady, /did not register a capability/);
});

test("a host adapter version mismatch rejects the mount", async () => {
  await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => ({
      name: "formatting",
      version: 2,
      sync: { format: () => "1" },
    }),
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady,
    /registers version 2 but the manifest requires version 1/);
});

test("a host adapter cannot register an undeclared operation", async () => {
  await setup([FORMAT_COMPONENT], {
    formatHost: "mochi-format.js",
    hostModuleFactory: async () => ({
      name: "formatting",
      version: 1,
      sync: { format: () => "1", extra: () => "2" },
    }),
  });

  const element = document.createElement("format-panel");
  document.body.appendChild(element);

  await assert.rejects(element._mochiReady, /undeclared operation 'extra'/);
});

test("manifest capability operations must be sync or async", async () => {
  const base = manifest([COMPONENT]);
  base.capabilities = {
    formatting: { version: 1, host: "mochi-format.js", operations: { format: "later" } },
  };
  await assert.rejects(
    setup([COMPONENT], { manifest: base }),
    /capability 'formatting' operation 'format' must be sync or async/
  );
});

test("manifest capability adapters must be local artifacts", async () => {
  const base = manifest([COMPONENT]);
  base.capabilities = {
    formatting: {
      version: 1,
      host: "https://cdn.example/mochi-format.js",
      operations: { format: "sync" },
    },
  };
  await assert.rejects(
    setup([COMPONENT], { manifest: base }),
    /capability 'formatting' has an invalid adapter location/
  );
});

const PROBE_COMPONENT = {
  tag_name: "probe-panel",
  class_name: "ProbePanel",
  chi_file: "probe-panel.chi",
  html_template: '<p class="value">{@result}</p>',
  css: "",
  bindings: [],
  events: [],
  capabilities: ["probe"],
};

function probeManifest() {
  const base = manifest([PROBE_COMPONENT]);
  base.capabilities = {
    probe: {
      version: 1,
      host: "mochi-probe.js",
      operations: { ping: "async" },
      packages: [],
    },
  };
  return base;
}

function probeLine(instance, args) {
  return JSON.stringify({
    __host: "capability_async",
    id: 1,
    instance: String(instance),
    capability: "probe",
    operation: "ping",
    args: args,
    callback: "on_ping",
  }) + "\n";
}

test("async host capabilities deliver typed results before the next patch", async () => {
  const seen = [];
  const { loader, module, log } = await setup([PROBE_COMPONENT], {
    manifest: probeManifest(),
    hostModuleFactory: async () => ({
      name: "probe",
      version: 1,
      async: {
        ping: async (argsJson) => {
          seen.push(JSON.parse(argsJson));
          return { count: 42, ok: true };
        },
      },
    }),
  });

  module.reuseInstance(7);
  module.queueEmit(probeLine(7, [41]));
  const element = document.createElement("probe-panel");
  document.body.appendChild(element);
  await element._mochiReady;
  await flushLifecycle();

  assert.deepEqual(seen, [[41]]);
  assert.deepEqual(log.deliveredHostResults, [{
    instance: "7",
    callback: "on_ping",
    envelope: { ok: true, value: { count: 42, ok: true }, error: null },
  }]);
  assert.equal(loader.debugStats().pendingHostRequests, 0);
});

test("async host capability errors reach the Ruby callback", async () => {
  const { module, log } = await setup([PROBE_COMPONENT], {
    manifest: probeManifest(),
    hostModuleFactory: async () => ({
      name: "probe",
      version: 1,
      async: {
        ping: async () => { throw new Error("probe unavailable"); },
      },
    }),
  });

  module.reuseInstance(8);
  module.queueEmit(probeLine(8, []));
  const element = document.createElement("probe-panel");
  document.body.appendChild(element);
  await element._mochiReady;
  await flushLifecycle();

  assert.deepEqual(log.deliveredHostResults[0].envelope, {
    ok: false,
    value: null,
    error: "probe unavailable",
  });
});

test("a host result for a disposed component is dropped", async () => {
  let resolvePing;
  const pending = new Promise((resolve) => { resolvePing = resolve; });
  const { loader, module, log } = await setup([PROBE_COMPONENT], {
    manifest: probeManifest(),
    hostModuleFactory: async () => ({
      name: "probe",
      version: 1,
      async: { ping: () => pending },
    }),
  });

  module.reuseInstance(9);
  module.queueEmit(probeLine(9, []));
  const element = document.createElement("probe-panel");
  document.body.appendChild(element);
  await element._mochiReady;
  await flushLifecycle();
  assert.equal(log.deliveredHostResults.length, 0);

  element.remove();
  await flushLifecycle();
  assert.equal(loader.debugStats().pendingHostRequests, 0);

  resolvePing({ late: true });
  await flushLifecycle();
  assert.equal(log.deliveredHostResults.length, 0);
});
