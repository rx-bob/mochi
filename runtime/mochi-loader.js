// mochi-loader.js - static Custom Element + Shadow DOM loader for mochi-gvm.
(function (global) {
  "use strict";

  var RITE_HEADER = new Uint8Array([0x52, 0x49, 0x54, 0x45, 0x30, 0x34, 0x30, 0x30, 0x00, 0x00]);
  var COMPONENT_DIR = "components/";
  var DEFAULT_MANIFEST = "mochi-manifest.json";

  var state = {
    manifest: null,
    manifestUrl: null,
    modulePromise: null,
    irepPromises: new Map(),
    internCache: new Map(),
    tags: new Set(),
    elements: new Map(),
    actionRouterInstalled: false,
    actionSupportCache: new Map()
  };

  function absoluteUrl(path, base) {
    return new URL(path, base).href;
  }

  function runtimeUrl(manifest, manifestUrl) {
    return absoluteUrl(manifest.wasm_file || "mochi-gvm.wasm", manifestUrl);
  }

  function jsUrl(manifest, manifestUrl) {
    if (manifest.js_file) return absoluteUrl(manifest.js_file, manifestUrl);
    var wasm = manifest.wasm_file || "mochi-gvm.wasm";
    return absoluteUrl(wasm.replace(/\.wasm($|\?)/, ".js$1"), manifestUrl);
  }

  function chiUrl(component, manifestUrl) {
    var path = component.chi_file || (component.tag_name + ".chi");
    if (path.indexOf("/") === -1) path = COMPONENT_DIR + path;
    return absoluteUrl(path, manifestUrl);
  }

  function encode(text) {
    return new TextEncoder().encode(text);
  }

  function decode(bytes) {
    return new TextDecoder().decode(bytes);
  }

  // Flattens top-level and conditional-branch bindings so every getter can be
  // registered with the VM at mount time, even while its branch is unmounted.
  function collectBindings(bindings, result) {
    (bindings || []).forEach(function (binding) {
      result.push(binding);
      (binding.branches || []).forEach(function (branch) {
        collectBindings(branch.bindings, result);
      });
    });
  }

  function flattenBindings(bindings) {
    var result = [];
    collectBindings(bindings, result);
    return result;
  }

  function lastError(module) {
    if (!module._mochi_last_error_offset || !module._mochi_last_error_len) return "";
    var offset = module._mochi_last_error_offset();
    var length = module._mochi_last_error_len();
    if (!offset || length <= 0) return "";
    return decode(module.HEAPU8.subarray(offset, offset + length));
  }

  function hasMethod(module, instance, methodName) {
    if (!module || typeof module._mochi_has_method !== "function") return true;
    return withUtf8(module, methodName, function (pointer, length) {
      return module._mochi_has_method(instance, pointer, length) === 1;
    });
  }

  function actionSupported(module, element, action) {
    var component = element._mochiComponent || {};
    var className = component.class_name || component.tag_name || "";
    var key = className + "\u0000" + action;
    if (state.actionSupportCache.has(key)) return state.actionSupportCache.get(key);

    var supported = hasMethod(module, element._mochiInstance, action);
    state.actionSupportCache.set(key, supported);
    return supported;
  }

  function ensureActionRouter() {
    if (state.actionRouterInstalled || !global.document) return;
    state.actionRouterInstalled = true;

    global.document.addEventListener("mochi:action", function (event) {
      var action = event && event.detail && event.detail.action;
      if (!action) return;

      state.elements.forEach(function (element) {
        element._dispatchAction(action);
      });
    });
  }

  // Drains Ruby `Mochi.emit("action")` calls. Actions are published on the
  // document so every mounted component can handle the ones it implements.
  function drainEmits(module) {
    if (!module || !module._mochi_emit_outbox_offset ||
        !module._mochi_emit_outbox_len || !module._mochi_emit_outbox_clear) {
      return;
    }
    var length = module._mochi_emit_outbox_len();
    if (length <= 0) return;
    var offset = module._mochi_emit_outbox_offset();
    var text = offset ? decode(module.HEAPU8.subarray(offset, offset + length)) : "";
    module._mochi_emit_outbox_clear();
    if (!text || !global.document) return;
    text.split("\n").forEach(function (action) {
      if (!action) return;
      global.document.dispatchEvent(new global.CustomEvent("mochi:action", {
        detail: { action: action }
      }));
    });
  }

  function withUtf8(module, text, callback) {
    var bytes = encode(text);
    var malloc = module._malloc || module._mochi_malloc;
    var free = module._free || module._mochi_free;
    var pointer = malloc(bytes.length + 1);

    if (!pointer) throw new Error("mochi-gvm: out of memory");

    module.HEAPU8.set(bytes, pointer);
    module.HEAPU8[pointer + bytes.length] = 0;

    try {
      return callback(pointer, bytes.length);
    } finally {
      if (free) free(pointer);
    }
  }

  function intern(module, name) {
    if (!name) return 0;
    if (state.internCache.has(name)) return state.internCache.get(name);

    var symbol = withUtf8(module, name, function (pointer, length) {
      return module._mochi_intern(pointer, length);
    });

    if (!symbol) throw new Error("mochi-gvm: failed to intern " + name);
    state.internCache.set(name, symbol);
    return symbol;
  }

  function loadScript(url) {
    return new Promise(function (resolve, reject) {
      var script = global.document.createElement("script");
      script.src = url;
      script.async = true;
      script.onload = function () { resolve(); };
      script.onerror = function () { reject(new Error("mochi-loader: failed to load " + url)); };
      global.document.head.appendChild(script);
    });
  }

  async function loadRuntime(manifest, manifestUrl) {
    if (state.modulePromise) return state.modulePromise;

    state.modulePromise = (async function () {
      var wasmUrl = runtimeUrl(manifest, manifestUrl);
      var factory = loader.moduleFactory || global.MochiModule;

      if (!factory) {
        await loadScript(jsUrl(manifest, manifestUrl));
        factory = global.MochiModule;
      }

      if (!factory) throw new Error("mochi-loader: MochiModule factory not found");

      var module = typeof factory === "function"
        ? await factory({
            locateFile: function (path) {
              return /\.wasm($|\?)/.test(path) ? wasmUrl : absoluteUrl(path, manifestUrl);
            }
          })
        : factory;

      if (!module || !module._mochi_init_runtime) {
        throw new Error("mochi-loader: invalid mochi-gvm module");
      }

      if (module._mochi_init_runtime() !== 0) {
        throw new Error("mochi-loader: runtime init failed: " + lastError(module));
      }

      return module;
    })().catch(function (error) {
      state.modulePromise = null;
      throw error;
    });

    return state.modulePromise;
  }

  async function loadComponentClass(component, manifest, manifestUrl) {
    var url = chiUrl(component, manifestUrl);
    var existing = state.irepPromises.get(url);
    if (existing) return existing;

    var promise = (async function () {
      var module = await loadRuntime(manifest, manifestUrl);
      var response = await global.fetch(url);
      if (!response.ok) throw new Error("mochi-loader: failed to fetch " + url);

      var stripped = new Uint8Array(await response.arrayBuffer());
      var bytes = new Uint8Array(RITE_HEADER.length + stripped.length);
      bytes.set(RITE_HEADER, 0);
      bytes.set(stripped, RITE_HEADER.length);

      var malloc = module._malloc || module._mochi_malloc;
      var free = module._free || module._mochi_free;
      var pointer = malloc(bytes.length);
      if (!pointer) throw new Error("mochi-gvm: out of memory");

      try {
        module.HEAPU8.set(bytes, pointer);
        if (module._mochi_load_irep(pointer, bytes.length) !== 0) {
          throw new Error("mochi-loader: load_irep failed for " + component.class_name + ": " + lastError(module));
        }
      } finally {
        if (free) free(pointer);
      }

      return module;
    })();

    state.irepPromises.set(url, promise);
    promise.catch(function () { state.irepPromises.delete(url); });
    return promise;
  }

  async function mountInstance(component, manifest, manifestUrl) {
    var module = await loadComponentClass(component, manifest, manifestUrl);
    var instance;

    withUtf8(module, component.class_name, function (pointer, length) {
      instance = module._mochi_mount_component(pointer, length);
    });

    if (instance === 0 || instance === 0n) {
      throw new Error("mochi-loader: mount failed for " + component.class_name + ": " + lastError(module));
    }

    flattenBindings(component.bindings).forEach(function (binding) {
      var symbol = intern(module, binding.getter_sym);
      if (module._mochi_register_binding(instance, binding.id, symbol) !== 0) {
        throw new Error("mochi-loader: binding registration failed for " + binding.getter_sym + ": " + lastError(module));
      }
    });

    if (hasMethod(module, instance, "mounted")) {
      var mounted = intern(module, "mounted");
      module._mochi_dispatch_event(instance, mounted);
    }

    return { module: module, instance: instance };
  }

  function resolveTarget(root, path) {
    var node = root;
    for (var i = 0; i < path.length; i++) {
      if (!node) return null;
      node = node.childNodes[path[i]];
    }
    return node || null;
  }

  function installBindingTarget(element, root, binding, context) {
    var path = binding.path || [];
    var node = resolveTarget(root, path);
    if (!node) {
      throw new Error("mochi-loader: missing binding path [" + path.join(", ") + "] for " + context);
    }

    if (binding.kind === "html" && node.nodeType === 3) {
      var span = global.document.createElement("span");
      span.textContent = node.textContent;
      node.parentNode.replaceChild(span, node);
      node = span;
    } else if (binding.kind === "text" && node.nodeType === 3) {
      textBindingState(node, binding);
    } else if (binding.kind === "attr" && node.nodeType === 1) {
      attrBindingState(node, binding);
    } else if (binding.kind === "prop" && node.nodeType !== 1) {
      throw new Error("mochi-loader: property binding target is not an element for " + context);
    }

    element.bindingTargets[binding.id] = node;
    element.bindingData[binding.id] = binding;
    return node;
  }

  function eventTarget(event, root, eventName) {
    var attribute = "data-mochi-" + eventName;
    var node = event.target;
    while (node && node !== root) {
      if (node.nodeType === 1 && node.hasAttribute(attribute)) return node;
      node = node.parentNode;
    }
    return null;
  }

  function eventPayload(target, event) {
    var source = event && event.target && event.target.nodeType === 1 ? event.target : target;
    var dataset = {};
    if (source && source.dataset) {
      Object.keys(source.dataset).forEach(function (key) {
        if (key.indexOf("mochi") === 0) return;
        dataset[key] = source.dataset[key];
      });
    }

    function axis(name) {
      return event && typeof event[name] === "number" ? event[name] : 0;
    }

    return {
      type: event ? event.type : "",
      value: source && "value" in source ? source.value : null,
      checked: !!(source && typeof source.checked === "boolean" && source.checked),
      key: event && event.key ? event.key : "",
      code: event && event.code ? event.code : "",
      shift_key: !!(event && event.shiftKey),
      ctrl_key: !!(event && event.ctrlKey),
      meta_key: !!(event && event.metaKey),
      alt_key: !!(event && event.altKey),
      client_x: axis("clientX"),
      client_y: axis("clientY"),
      offset_x: axis("offsetX"),
      offset_y: axis("offsetY"),
      button: event && typeof event.button === "number" ? event.button : 0,
      target_id: source && source.id ? source.id : "",
      dataset: dataset
    };
  }

  function eventArguments(target, eventName) {
    var raw = target.getAttribute("data-mochi-args-" + eventName);
    if (!raw) return [];

    var parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw new Error("mochi-loader: invalid event arguments for " + eventName);
    }
    if (!Array.isArray(parsed)) {
      throw new Error("mochi-loader: event arguments for " + eventName + " must be an array");
    }
    return parsed;
  }

  function literalEventArgument(descriptor) {
    var value = descriptor.value;
    if (descriptor.literal_type === "string") return value === undefined ? "" : value;
    if (descriptor.literal_type === "number") return Number(value);
    if (descriptor.literal_type === "boolean") return value === "true";
    if (descriptor.literal_type === "null") return null;
    return value === undefined ? null : value;
  }

  // Ruby expressions used as event arguments are resolved from cached binding
  // values. The compiler registers a hidden binding for each expression, so the
  // VM evaluates it once and the loader can pass the resulting value.
  function resolveEventExpression(element, expression) {
    var bindingData = element.bindingData || {};
    var bindingValues = element.bindingValues || {};
    var ids = Object.keys(bindingData);
    for (var i = 0; i < ids.length; i++) {
      var binding = bindingData[ids[i]];
      if (binding && binding.getter_expr === expression &&
          Object.prototype.hasOwnProperty.call(bindingValues, binding.id)) {
        return bindingValues[binding.id];
      }
    }
    throw new Error("mochi-loader: unresolved event argument expression " + expression);
  }

  function eventArgumentValue(element, descriptor, target, payload) {
    if (descriptor.kind === "event") return payload;
    if (descriptor.kind === "element") {
      throw new Error("mochi-loader: DOM elements cannot be passed to Ruby event handlers; use $event");
    }
    if (descriptor.kind === "literal") return literalEventArgument(descriptor);
    if (descriptor.kind === "expr") {
      return resolveEventExpression(element, String(descriptor.value || "").trim());
    }
    throw new Error("mochi-loader: unknown event argument kind " + descriptor.kind);
  }

  function dispatchEventArgs(module, instance, methodSymbol, args) {
    if (typeof module._mochi_dispatch_event_args !== "function") {
      throw new Error("mochi-loader: runtime does not support event arguments");
    }
    return withUtf8(module, JSON.stringify(args), function (pointer, length) {
      return module._mochi_dispatch_event_args(instance, methodSymbol, pointer, length) === 1;
    });
  }

  function requiredArgumentCount(module, instance, methodSymbol) {
    if (typeof module._goose_vm_method_req_argc !== "function") return -1;
    var required = module._goose_vm_method_req_argc(instance, methodSymbol);
    return typeof required === "bigint" ? Number(required) : required;
  }

  function readU16LE(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  function readU32LE(bytes, offset) {
    return (bytes[offset] | (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
  }

  function decodePatches(module, count) {
    var offset = module._mochi_patch_buffer_offset();
    var length = module._mochi_patch_buffer_len();
    var heap = module.HEAPU8;
    var end = offset + length;
    var patches = [];
    var at = offset;

    while (at + 6 <= end && patches.length < count) {
      var bindingId = readU16LE(heap, at);
      var byteLength = readU32LE(heap, at + 2);
      at += 6;
      if (at + byteLength > end) break;
      patches.push({
        bindingId: bindingId,
        value: decode(heap.subarray(at, at + byteLength))
      });
      at += byteLength;
    }

    if (patches.length !== count) {
      throw new Error("mochi-loader: truncated patch frame (" + patches.length + "/" + count + ")");
    }

    return patches;
  }

  function substitute(template, ids, values) {
    var index = 0;
    return String(template || "").replace(/\{([^}]+)\}/g, function (match) {
      var id = ids[index++];
      if (id === undefined || !Object.prototype.hasOwnProperty.call(values, id)) return match;
      return values[id];
    });
  }

  function textBindingState(target, binding) {
    if (!target.__mochiText) {
      target.__mochiText = {
        template: binding.template_text || target.textContent || "",
        ids: [],
        values: {}
      };
    }
    if (target.__mochiText.ids.indexOf(binding.id) === -1) {
      target.__mochiText.ids.push(binding.id);
    }
    return target.__mochiText;
  }

  function attrBindingState(target, binding) {
    if (!target.__mochiAttrs) target.__mochiAttrs = {};
    var name = binding.attr_name;
    if (!target.__mochiAttrs[name]) {
      target.__mochiAttrs[name] = {
        template: binding.template_text || "",
        ids: [],
        values: {}
      };
    }
    var state = target.__mochiAttrs[name];
    if (state.ids.indexOf(binding.id) === -1) state.ids.push(binding.id);
    return state;
  }

  function fragmentFor(html) {
    var template = global.document.createElement("template");
    template.innerHTML = html || "";
    return template.content;
  }

  function applyTextPatch(target, binding, value) {
    var state = textBindingState(target, binding);
    if (state.values[binding.id] === value) return;
    state.values[binding.id] = value;
    target.textContent = substitute(state.template, state.ids, state.values);
  }

  function applyHtmlPatch(target, binding, value) {
    if (target.__mochiHtmlValue === value) return;
    target.__mochiHtmlValue = value;
    target.innerHTML = value;
  }

  function applyAttrPatch(target, binding, value) {
    var state = attrBindingState(target, binding);
    if (state.values[binding.id] === value) return;
    state.values[binding.id] = value;
    if (value === "" || value === "false") {
      target.removeAttribute(binding.attr_name);
    } else {
      target.setAttribute(binding.attr_name, substitute(state.template, state.ids, state.values));
    }
  }

  function applyPropPatch(target, binding, value) {
    var property = binding.attr_name;
    if (!property) return;

    var next;
    if (property === "checked") {
      next = value === "true" || value === "checked" || value === "1";
    } else {
      next = value === null || value === undefined ? "" : String(value);
    }

    if (target[property] === next) return;
    target[property] = next;
  }

  function removeNodes(nodes) {
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].parentNode) nodes[i].parentNode.removeChild(nodes[i]);
    }
  }

  function conditionalBranches(binding) {
    if (binding.branches && binding.branches.length) return binding.branches;
    return [{ html_template: binding.template_text || "", bindings: [], events: [] }];
  }

  function branchIndexFor(value, branchCount) {
    if (value === "true") return branchCount > 0 ? 0 : -1;
    if (value === "false" || value === "-1" || value === "" || value === null || value === undefined) return -1;

    var index = Number(value);
    if (!Number.isInteger(index) || index < 0 || index >= branchCount) return -1;
    return index;
  }

  function unmountConditionalBranch(element, state) {
    var anchor = state.anchor;
    var endNode = state.endNode;
    if (anchor && anchor.parentNode) {
      // Remove the whole inserted range, including nodes mounted by nested
      // conditionals or each bindings after top-level anchors in this branch.
      var node = anchor.nextSibling;
      while (node && node !== endNode) {
        var next = node.nextSibling;
        if (node.parentNode) node.parentNode.removeChild(node);
        node = next;
      }
    } else {
      removeNodes(state.nodes || []);
    }

    (state.bindingIds || []).forEach(function (bindingId) {
      delete element.bindingTargets[bindingId];
    });
    state.nodes = [];
    state.bindingIds = [];
    state.endNode = null;
    state.index = -1;
  }

  function mountConditionalBranch(element, target, branch, state, index) {
    var parent = target.parentNode;
    if (!parent) return;

    var fragment = fragmentFor(branch.html_template || "");
    var branchBindings = branch.bindings || [];
    var endNode = target.nextSibling;

    branchBindings.forEach(function (binding) {
      installBindingTarget(element, fragment, binding, "conditional branch");
    });

    var nodes = Array.from(fragment.childNodes);
    parent.insertBefore(fragment, endNode);

    state.anchor = target;
    state.endNode = endNode;
    state.nodes = nodes;
    state.index = index;
    state.bindingIds = flattenBindings(branchBindings).map(function (binding) { return binding.id; });

    branchBindings.forEach(function (binding) {
      if (!Object.prototype.hasOwnProperty.call(element.bindingValues, binding.id)) return;
      var childTarget = element.bindingTargets[binding.id];
      if (childTarget) applyBindingValue(element, childTarget, binding, element.bindingValues[binding.id]);
    });
  }

  function applyCondPatch(element, target, binding, value) {
    var branches = conditionalBranches(binding);
    var nextIndex = branchIndexFor(value, branches.length);
    var state = target.__mochiCond;
    if (!state) state = target.__mochiCond = { index: -1, anchor: target, endNode: null, nodes: [], bindingIds: [] };
    if (state.index === nextIndex) return;

    if (state.index >= 0) unmountConditionalBranch(element, state);
    if (nextIndex >= 0 && branches[nextIndex]) {
      mountConditionalBranch(element, target, branches[nextIndex], state, nextIndex);
    }
  }

  function applyBindingValue(element, target, binding, value) {
    if (binding.kind === "text") {
      applyTextPatch(target, binding, value);
    } else if (binding.kind === "html") {
      applyHtmlPatch(target, binding, value);
    } else if (binding.kind === "attr") {
      applyAttrPatch(target, binding, value);
    } else if (binding.kind === "prop") {
      applyPropPatch(target, binding, value);
    } else if (binding.kind === "cond") {
      applyCondPatch(element, target, binding, value);
    } else if (binding.kind === "each") {
      applyEachPatch(target, binding, value);
    }
  }

  function itemKey(item, index) {
    if (item && typeof item === "object") {
      if (item.key !== undefined && item.key !== null) return String(item.key);
      if (item.id !== undefined && item.id !== null) return String(item.id);
    }
    return String(index);
  }

  function itemLookup(item, expression) {
    var path = expression.trim();
    var parts = path.split(".");
    var value = item;
    for (var i = 0; i < parts.length; i++) {
      if (value === null || value === undefined) break;
      value = value[parts[i]];
    }
    if (value !== undefined || parts.length <= 1) return value;
    return item[parts[parts.length - 1]];
  }

  function renderEachTemplate(template, item, index) {
    return String(template || "").replace(/\{([^}]+)\}/g, function (match, expression) {
      if (expression.trim() === "index") return String(index);
      var value = itemLookup(item, expression);
      if (value === undefined || value === null) return "";
      if (typeof value === "object") return match;
      return String(value);
    });
  }

  function eachItemHtml(binding, item, index) {
    if (item && typeof item === "object" && typeof item.html === "string") return item.html;
    if (typeof item === "string") return item;
    return renderEachTemplate(binding.template_text, item, index);
  }

  function entryFollows(entry, cursor) {
    if (entry.nodes.length === 0) return true;
    if (entry.nodes[0].previousSibling !== cursor) return false;
    for (var i = 1; i < entry.nodes.length; i++) {
      if (entry.nodes[i].previousSibling !== entry.nodes[i - 1]) return false;
    }
    return true;
  }

  function applyEachPatch(target, binding, value) {
    var items;
    if (!value) {
      items = [];
    } else {
      try {
        items = JSON.parse(value);
      } catch (error) {
        throw new Error("mochi-loader: invalid each patch for binding " + binding.id);
      }
      if (!Array.isArray(items)) {
        throw new Error("mochi-loader: each patch must be an array for binding " + binding.id);
      }
    }

    var state = target.__mochiEach;
    if (!state) state = target.__mochiEach = { items: new Map() };
    var previous = state.items;
    var next = new Map();
    var ordered = [];
    var parent = target.parentNode;
    if (!parent) return;

    items.forEach(function (item, index) {
      var key = itemKey(item, index);
      var html = eachItemHtml(binding, item, index);
      var entry = previous.get(key);
      if (!entry || entry.html !== html) {
        entry = { html: html, nodes: Array.from(fragmentFor(html).childNodes) };
      }
      next.set(key, entry);
      ordered.push(entry);
    });

    var live = new Set(ordered);
    previous.forEach(function (entry) {
      if (!live.has(entry)) removeNodes(entry.nodes);
    });

    var cursor = target;
    ordered.forEach(function (entry) {
      if (entry.nodes.length === 0) return;
      if (!entryFollows(entry, cursor)) {
        entry.nodes.forEach(function (node) {
          parent.insertBefore(node, cursor.nextSibling);
          cursor = node;
        });
      } else {
        cursor = entry.nodes[entry.nodes.length - 1];
      }
    });

    state.items = next;
  }

  function applyPatchRecord(element, record) {
    var binding = element.bindingData[record.bindingId];
    if (!binding) {
      throw new Error("mochi-loader: patch for unknown binding " + record.bindingId);
    }

    // Cache every value even when its branch is unmounted. Mounting a branch
    // replays this cache so late-arriving patches are not lost.
    element.bindingValues[record.bindingId] = record.value;
    var target = element.bindingTargets[record.bindingId];
    if (!target) return;

    applyBindingValue(element, target, binding, record.value);
  }

  function applyPatches(target, module) {
    var element = target && target.bindingTargets ? target : state.elements.get(String(target));
    if (!element) return;
    var activeModule = module || element._mochiModule;
    var instance = element._mochiInstance;
    if (!activeModule || instance === null || instance === undefined) return;
    if (typeof activeModule._mochi_flush_patches !== "function") return;

    var count = activeModule._mochi_flush_patches(instance);
    if (count < 0) {
      throw new Error("mochi-loader: patch flush failed: " + lastError(activeModule));
    }
    if (count === 0) return;

    decodePatches(activeModule, count).forEach(function (record) {
      applyPatchRecord(element, record);
    });
  }

  function defineComponent(component, manifestUrl) {
    var tag = component.tag_name;
    if (!tag || state.tags.has(tag) || global.customElements.get(tag)) return;

    var template = global.document.createElement("template");
    template.innerHTML = component.html_template || "";
    var bindings = component.bindings || [];
    var allBindings = flattenBindings(bindings);
    var eventNames = [];
    function addEventName(name) {
      if (name && eventNames.indexOf(name) === -1) eventNames.push(name);
    }
    (component.events || []).forEach(function (event) { addEventName(event.event); });
    allBindings.forEach(function (binding) {
      (binding.branches || []).forEach(function (branch) {
        (branch.events || []).forEach(function (event) { addEventName(event.event); });
      });
    });

    var Element = class extends global.HTMLElement {
      constructor() {
        super();
        this.bindingTargets = {};
        this.bindingData = {};
        this.bindingValues = {};
        allBindings.forEach(function (binding) {
          this.bindingData[binding.id] = binding;
        }, this);
        this.refs = this.bindingTargets;
        this._mochiComponent = component;
        this._mochiManifestUrl = manifestUrl;
        this._mochiReady = null;
        this._mochiModule = null;
        this._mochiInstance = null;
        this._mochiDisconnected = false;
        this._mochiUnmounted = false;
      }

      connectedCallback() {
        ensureActionRouter();
        if (this.shadowRoot) return;

        var root = this.attachShadow({ mode: "open" });
        var style = global.document.createElement("style");
        style.textContent = component.css || "";
        root.appendChild(style);

        var fragment = template.content.cloneNode(true);
        this._resolveBindings(fragment);
        root.appendChild(fragment);
        this._attachEvents(root);

        var element = this;
        this._mochiReady = mountInstance(component, state.manifest, manifestUrl).then(function (mounted) {
          element._mochiModule = mounted.module;
          element._mochiInstance = mounted.instance;

          if (element._mochiDisconnected) {
            element._unmount(mounted.module, mounted.instance);
            return mounted;
          }

          state.elements.set(String(mounted.instance), element);
          applyPatches(element, mounted.module);
          drainEmits(mounted.module);
          return mounted;
        }).catch(function (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " mount failed", error);
          throw error;
        });
      }

      disconnectedCallback() {
        this._mochiDisconnected = true;

        if (this._mochiModule && this._mochiInstance !== null && this._mochiInstance !== undefined) {
          this._unmount(this._mochiModule, this._mochiInstance);
          return;
        }

        var element = this;
        if (this._mochiReady) {
          this._mochiReady.then(function (mounted) {
            element._unmount(mounted.module, mounted.instance);
          }).catch(function () {});
        }
      }

      _unmount(module, instance) {
        if (this._mochiUnmounted) return;
        this._mochiUnmounted = true;

        var key = String(instance);
        if (state.elements.get(key) === this) state.elements.delete(key);

        try {
          if (hasMethod(module, instance, "unmounted")) {
            var symbol = intern(module, "unmounted");
            if (module._mochi_dispatch_event(instance, symbol) !== 1) {
              throw new Error("mochi-loader: unmounted dispatch failed for " + tag + ": " + lastError(module));
            }
          }
          drainEmits(module);
        } catch (error) {
          this.mochiError = error;
          console.error("[mochi] " + tag + " unmount failed", error);
        }
      }

      _resolveBindings(root) {
        for (var i = 0; i < bindings.length; i++) {
          installBindingTarget(this, root, bindings[i], tag);
        }
      }

      _attachEvents(root) {
        var element = this;
        eventNames.forEach(function (eventName) {
          root.addEventListener(eventName, function (event) {
            var target = eventTarget(event, root, eventName);
            if (target) element._dispatch(target, event);
          });
        });
      }

      _dispatch(target, event) {
        var element = this;
        var method = target.getAttribute("data-mochi-" + event.type);
        if (!method || !this._mochiReady) return;

        var payload = eventPayload(target, event);
        var descriptors;

        try {
          descriptors = eventArguments(target, event.type);
        } catch (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " event failed", error);
          return;
        }

        this._mochiReady.then(function (mounted) {
          var symbol = intern(mounted.module, method);
          var dispatched;

          if (descriptors.length > 0) {
            var args = descriptors.map(function (descriptor) {
              return eventArgumentValue(element, descriptor, target, payload);
            });
            dispatched = dispatchEventArgs(mounted.module, mounted.instance, symbol, args);
          } else if (requiredArgumentCount(mounted.module, mounted.instance, symbol) === 1) {
            dispatched = dispatchEventArgs(mounted.module, mounted.instance, symbol, [payload]);
          } else {
            dispatched = mounted.module._mochi_dispatch_event(mounted.instance, symbol) === 1;
          }

          if (!dispatched) {
            throw new Error("mochi-loader: event dispatch failed for " + method + ": " + lastError(mounted.module));
          }
          applyPatches(element, mounted.module);
          drainEmits(mounted.module);
        }).catch(function (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " event failed", error);
        });
      }

      _dispatchAction(action) {
        if (!action || this._mochiDisconnected) return;

        var module = this._mochiModule;
        var instance = this._mochiInstance;
        if (!module || instance === null || instance === undefined) return;
        if (state.elements.get(String(instance)) !== this) return;

        try {
          if (!actionSupported(module, this, action)) return;

          var symbol = intern(module, action);
          if (module._mochi_dispatch_event(instance, symbol) !== 1) {
            throw new Error("mochi-loader: action dispatch failed for " + action + ": " + lastError(module));
          }
          if (!this._mochiDisconnected) {
            applyPatches(this, module);
            drainEmits(module);
          }
        } catch (error) {
          this.mochiError = error;
          console.error("[mochi] " + tag + " action failed", error);
        }
      }
    };

    state.tags.add(tag);
    global.customElements.define(tag, Element);
  }

  async function boot(url, options) {
    options = options || {};
    if (options.moduleFactory) loader.moduleFactory = options.moduleFactory;

    var manifestUrl = absoluteUrl(url || DEFAULT_MANIFEST, global.document.baseURI);
    if (state.manifestUrl === manifestUrl && state.manifest) return state.manifest;

    var response = await global.fetch(manifestUrl);
    if (!response.ok) throw new Error("mochi-loader: failed to fetch " + manifestUrl);

    var manifest = await response.json();
    if (Array.isArray(manifest)) manifest = { components: manifest };
    if (!manifest.components) manifest.components = [];

    state.actionSupportCache.clear();
    state.manifest = manifest;
    state.manifestUrl = manifestUrl;

    for (var i = 0; i < manifest.components.length; i++) {
      defineComponent(manifest.components[i], manifestUrl);
    }

    return manifest;
  }

  var loader = {
    boot: boot,
    moduleFactory: null,
    applyPatches: applyPatches,
    get manifest() { return state.manifest; },
    get components() { return state.manifest ? state.manifest.components : []; }
  };

  global.MochiLoader = loader;
  if (typeof module === "object" && module.exports) module.exports = loader;

  if (global.document && global.document.currentScript) {
    var script = global.document.currentScript;
    if (script.dataset.mochiAutoBoot !== "false") {
      var manifestPath = script.dataset.mochiManifest || DEFAULT_MANIFEST;
      var start = function () {
        boot(manifestPath).catch(function (error) {
          console.error("[mochi] loader boot failed", error);
        });
      };
      if (global.document.readyState === "loading") {
        global.document.addEventListener("DOMContentLoaded", start, { once: true });
      } else {
        start();
      }
    }
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
