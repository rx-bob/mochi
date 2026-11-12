// mochi-loader.js - static Custom Element + Shadow DOM loader for mochi-gvm.
(function (global) {
  "use strict";

  var RITE_HEADER = new Uint8Array([0x52, 0x49, 0x54, 0x45, 0x30, 0x34, 0x30, 0x30, 0x00, 0x00]);
  var COMPONENT_DIR = "components/";
  var DEFAULT_MANIFEST = "mochi-manifest.json";
  var MAX_PENDING_FETCHES = 256;

  // Custom element reactions for a same-task DOM move run before queued
  // microtasks, so deferring disposal one microtask distinguishes a renderer
  // move from a final removal without guessing which code moved the node.
  var deferDisposal = typeof global.queueMicrotask === "function"
    ? global.queueMicrotask
    : function (callback) { Promise.resolve().then(callback); };

  var state = {
    manifest: null,
    manifestUrl: null,
    modulePromise: null,
    activeModule: null,
    loadChain: Promise.resolve(),
    irepPromises: new Map(),
    internCache: new Map(),
    tags: new Set(),
    elements: new Map(),
    pendingFetches: [],
    timers: new Map(),
    unmountedInstances: new Set(),
    nextMountToken: 0,
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
    var path = typeof component === "string"
      ? component
      : (component.chi_file || (component.tag_name + ".chi"));
    if (path.indexOf("/") === -1) path = COMPONENT_DIR + path;
    return absoluteUrl(path, manifestUrl);
  }

  function encode(text) {
    return new TextEncoder().encode(text);
  }

  function decode(bytes) {
    return new TextDecoder().decode(bytes);
  }

  function unescapeBraces(text) {
    return String(text || "").replace(/\uE000/g, "{").replace(/\uE001/g, "}");
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

  function currentRoutePath() {
    if (!global.location) return "/";
    if (global.location.hash && global.location.hash.length > 1) {
      return global.location.hash.slice(1);
    }
    return global.location.pathname || "/";
  }

  function syncRouteToVm(module) {
    if (!module || typeof module._mochi_set_route_state !== "function") return;
    var route = currentRoutePath();
    withUtf8(module, route, function (ptr, len) {
      module._mochi_set_route_state(ptr, len);
    });
  }

  function seedStorageToVm(module) {
    if (!module || typeof module._mochi_seed_storage !== "function") return;
    try {
      var storage = global.localStorage;
      if (!storage) return;
      for (var i = 0; i < storage.length; i++) {
        var key = storage.key(i);
        if (key === null) continue;
        var val = storage.getItem(key);
        if (val === null) continue;
        withUtf8(module, key, function (kPtr, kLen) {
          withUtf8(module, val, function (vPtr, vLen) {
            module._mochi_seed_storage(kPtr, kLen, vPtr, vLen);
          });
        });
      }
    } catch (error) {
      // Ignore storage access errors in restricted environments.
    }
  }

  function notifyRouteChange(route) {
    if (state.activeModule) syncRouteToVm(state.activeModule);
    state.elements.forEach(function (element) {
      element._dispatchAction({ action: "on_route", payload: route, hasPayload: true });
    });
  }

  function ensureActionRouter() {
    if (state.actionRouterInstalled || !global.document) return;
    state.actionRouterInstalled = true;

    global.document.addEventListener("mochi:action", function (event) {
      var detail = event && event.detail;
      if (!detail || !detail.action) return;

      state.elements.forEach(function (element) {
        element._dispatchAction(detail);
      });
    });

    if (typeof global.addEventListener === "function") {
      global.addEventListener("popstate", function () {
        notifyRouteChange(currentRoutePath());
      });
      global.addEventListener("hashchange", function () {
        notifyRouteChange(currentRoutePath());
      });
    }

    global.document.addEventListener("keydown", function (event) {
      if (!event) return;
      var targetNode = event.target;
      var targetTag = targetNode && targetNode.tagName ? String(targetNode.tagName).toLowerCase() : "";
      var payload = {
        type: "keydown",
        key: event.key || "",
        code: event.code || "",
        shift_key: !!event.shiftKey,
        ctrl_key: !!event.ctrlKey,
        meta_key: !!event.metaKey,
        alt_key: !!event.altKey,
        target_tag: targetTag
      };
      state.elements.forEach(function (element) {
        element._dispatchAction({ action: "on_key", payload: payload, hasPayload: true });
      });
    });
  }

  function parseEmitLine(line) {
    var parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      return { action: line };
    }
    if (typeof parsed === "string") return { action: parsed };
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { action: line };
    if (typeof parsed.__host === "string") return parsed;
    if (typeof parsed.action !== "string") return null;
    return parsed;
  }

  function parseFetchLine(line) {
    if (!line) return null;
    if (line.charAt(0) === "{") {
      var parsed;
      try {
        parsed = JSON.parse(line);
      } catch (error) {
        return null;
      }
      if (!parsed || typeof parsed !== "object" ||
          typeof parsed.instance !== "string" ||
          typeof parsed.url !== "string" ||
          typeof parsed.callback !== "string") {
        return null;
      }
      return {
        id: parsed.id,
        instance: parsed.instance,
        url: parsed.url,
        callback: parsed.callback,
        options: parsed.options && typeof parsed.options === "object" ? parsed.options : {}
      };
    }

    // Legacy request lines were "id|component|url|callback".
    var first = line.indexOf("|");
    var second = first >= 0 ? line.indexOf("|", first + 1) : -1;
    var third = second >= 0 ? line.indexOf("|", second + 1) : -1;
    if (first < 0 || second < 0 || third < 0) return null;
    var id = Number(line.slice(0, first));
    if (!Number.isFinite(id)) return null;
    return {
      id: id,
      instance: line.slice(first + 1, second),
      url: line.slice(second + 1, third),
      callback: line.slice(third + 1),
      options: {}
    };
  }

  function fetchElement(request) {
    var element = state.elements.get(String(request.instance));
    if (!element || element._mochiDisconnected || element._mochiUnmounted) return null;
    if (request.mountToken !== undefined && element._mochiMountToken !== request.mountToken) {
      return null;
    }
    return element;
  }

  function fetchResponseData(body, contentType) {
    if (!body) return null;
    if (contentType && contentType.indexOf("json") === -1) return null;
    try {
      return JSON.parse(body);
    } catch (error) {
      return null;
    }
  }

  function fetchResponseEnvelope(response, body) {
    var status = response && typeof response.status === "number" ? response.status : 0;
    var ok = response && typeof response.ok === "boolean"
      ? response.ok
      : status >= 200 && status < 300;
    var contentType = "";
    try {
      if (response && response.headers && typeof response.headers.get === "function") {
        contentType = response.headers.get("content-type") || "";
      }
    } catch (error) {
      contentType = "";
    }
    var error = null;
    if (!ok) {
      var statusText = response && response.statusText ? " " + response.statusText : "";
      error = "HTTP " + status + statusText;
    }
    return {
      status: status,
      ok: ok,
      body: typeof body === "string" ? body : "",
      data: fetchResponseData(body, contentType),
      error: error
    };
  }

  function fetchNetworkEnvelope(error) {
    var message = error && error.message ? error.message : String(error || "fetch failed");
    return { status: 0, ok: false, body: "", data: null, error: message };
  }

  function writeFetchEnvelope(module, element, request, envelope) {
    var offset = module._mochi_fetch_inbox_offset ? module._mochi_fetch_inbox_offset() : 0;
    var capacity = module._mochi_fetch_inbox_capacity ? module._mochi_fetch_inbox_capacity() : 0;
    var text = JSON.stringify(envelope);
    var bytes = encode(text);
    if (!offset || capacity <= 0 || bytes.length + 1 > capacity) {
      text = JSON.stringify({
        status: 0,
        ok: false,
        body: "",
        data: null,
        error: "fetch response too large"
      });
      bytes = encode(text);
      if (!offset || capacity <= 0 || bytes.length + 1 > capacity) {
        throw new Error("mochi-loader: fetch response exceeds inbox capacity");
      }
    }
    module.HEAPU8.set(bytes, offset);
    var delivered = false;
    withUtf8(module, request.callback, function (pointer, length) {
      delivered = module._mochi_deliver_fetch(
        element._mochiInstance, pointer, length, bytes.length) === 0;
    });
    if (!delivered) {
      throw new Error("mochi-loader: fetch callback failed for " +
        request.callback + ": " + lastError(module));
    }
  }

  function deliverFetch(module, element, request, envelope) {
    var liveElement = fetchElement(request);
    if (!liveElement || liveElement !== element) return;
    try {
      writeFetchEnvelope(module, element, request, envelope);
      if (!element._mochiDisconnected) {
        applyPatches(element, module);
        drainEmits(module);
        drainFetches(module);
      }
    } catch (error) {
      element.mochiError = error;
      console.error("[mochi] " + (element._mochiComponent || {}).tag_name + " fetch failed", error);
    }
  }

  function startFetch(module, request, element) {
    // Capture the mount attempt so a response that arrives after disposal
    // cannot reach a later component that reused the VM instance slot.
    request.mountToken = element._mochiMountToken;
    if (typeof global.fetch !== "function") {
      deliverFetch(module, element, request, fetchNetworkEnvelope("fetch unavailable"));
      return;
    }

    var options = request.options && typeof request.options === "object" ? request.options : {};
    var responsePromise;
    try {
      responsePromise = global.fetch(request.url, options);
    } catch (error) {
      deliverFetch(module, element, request, fetchNetworkEnvelope(error));
      return;
    }

    Promise.resolve(responsePromise).then(function (response) {
      if (!fetchElement(request)) return null;
      var bodyPromise = response && typeof response.text === "function"
        ? response.text()
        : Promise.resolve("");
      return Promise.resolve(bodyPromise).then(function (body) {
        if (!fetchElement(request)) return;
        deliverFetch(module, element, request, fetchResponseEnvelope(response, body));
      });
    }).catch(function (error) {
      if (!fetchElement(request)) return;
      deliverFetch(module, element, request, fetchNetworkEnvelope(error));
    });
  }

  // Drains Ruby `Mochi.fetch` requests. Requests for instances that have not
  // mounted yet stay pending so a concurrent mount cannot consume them.
  function drainFetches(module) {
    if (!module || !module._mochi_fetch_outbox_offset ||
        !module._mochi_fetch_outbox_len || !module._mochi_fetch_outbox_clear) {
      return;
    }
    var requests = state.pendingFetches;
    state.pendingFetches = [];
    var length = module._mochi_fetch_outbox_len();
    if (length > 0) {
      var offset = module._mochi_fetch_outbox_offset();
      var text = offset ? decode(module.HEAPU8.subarray(offset, offset + length)) : "";
      module._mochi_fetch_outbox_clear();
      if (text) {
        text.split("\n").forEach(function (line) {
          var request = parseFetchLine(line);
          if (request) requests.push(request);
        });
      }
    }
    requests.forEach(function (request) {
      var element = fetchElement(request);
      if (element) {
        startFetch(module, request, element);
        return;
      }
      if (!state.unmountedInstances.has(String(request.instance))
          && state.pendingFetches.length < MAX_PENDING_FETCHES) {
        state.pendingFetches.push(request);
      }
    });
  }

  function clearTimerEntry(id) {
    var record = state.timers.get(id);
    if (!record) return;
    if (record.kind === "every") {
      clearInterval(record.handle);
    } else {
      clearTimeout(record.handle);
    }
    state.timers.delete(id);
  }

  function handleHostCommand(module, entry) {
    var hostKind = entry.__host;
    if (hostKind === "storage_set") {
      try {
        if (global.localStorage && typeof entry.key === "string") {
          global.localStorage.setItem(entry.key, String(entry.value !== undefined ? entry.value : ""));
        }
      } catch (error) {}
      return;
    }
    if (hostKind === "storage_remove") {
      try {
        if (global.localStorage && typeof entry.key === "string") {
          global.localStorage.removeItem(entry.key);
        }
      } catch (error) {}
      return;
    }
    if (hostKind === "set_route") {
      var path = typeof entry.path === "string" ? entry.path : "/";
      try {
        if (global.history && typeof global.history.pushState === "function") {
          var targetUrl = path.charAt(0) === "#" || path.charAt(0) === "/" ? path : "#" + path;
          global.history.pushState(null, "", targetUrl);
        }
      } catch (error) {}
      notifyRouteChange(path);
      return;
    }
    if (hostKind === "timer") {
      var timerId = Number(entry.id);
      if (entry.kind === "cancel") {
        clearTimerEntry(timerId);
        return;
      }
      var ms = Math.max(0, Number(entry.ms) || 0);
      var instanceKey = String(entry.instance || "");
      var callbackName = String(entry.callback || "");
      if (!callbackName) return;
      var liveElement = state.elements.get(instanceKey);
      var mountToken = liveElement ? liveElement._mochiMountToken : undefined;

      var invokeTimer = function () {
        if (entry.kind !== "every") state.timers.delete(timerId);
        var element = state.elements.get(instanceKey);
        if (!element || element._mochiDisconnected || element._mochiUnmounted ||
            element._mochiMountToken !== mountToken) {
          clearTimerEntry(timerId);
          return;
        }
        try {
          var symbol = intern(module, callbackName);
          module._mochi_dispatch_event(element._mochiInstance, symbol);
          applyPatches(element, module);
          drainEmits(module);
          drainFetches(module);
        } catch (error) {
          element.mochiError = error;
          console.error("[mochi] timer callback failed", error);
        }
      };

      var handle = entry.kind === "every"
        ? setInterval(invokeTimer, ms)
        : setTimeout(invokeTimer, ms);
      state.timers.set(timerId, {
        id: timerId,
        instance: instanceKey,
        mountToken: mountToken,
        kind: entry.kind,
        handle: handle
      });
    }
  }

  // Drains Ruby `Mochi.emit` and `Mochi.*` host calls.
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
    if (!text) return;
    text.split("\n").forEach(function (line) {
      if (!line) return;
      var entry = parseEmitLine(line);
      if (!entry) return;
      if (typeof entry.__host === "string") {
        handleHostCommand(module, entry);
        return;
      }
      if (!entry.action || !global.document) return;
      global.document.dispatchEvent(new global.CustomEvent("mochi:action", {
        detail: {
          action: entry.action,
          target: entry.target === undefined ? null : entry.target,
          payload: entry.payload,
          hasPayload: Object.prototype.hasOwnProperty.call(entry, "payload") &&
            entry.payload !== null && entry.payload !== undefined
        }
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

      state.activeModule = module;
      seedStorageToVm(module);
      syncRouteToVm(module);
      return module;
    })().catch(function (error) {
      state.modulePromise = null;
      throw error;
    });

    return state.modulePromise;
  }

  function loadIrepUrl(url, label, manifest, manifestUrl) {
    var existing = state.irepPromises.get(url);
    if (existing) return existing;

    var promise = state.loadChain.then(async function () {
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
          throw new Error("mochi-loader: load_irep failed for " + label + ": " + lastError(module));
        }
      } finally {
        if (free) free(pointer);
      }

      return module;
    });

    state.loadChain = promise.catch(function () {});
    state.irepPromises.set(url, promise);
    promise.catch(function () { state.irepPromises.delete(url); });
    return promise;
  }

  async function loadComponentClass(component, manifest, manifestUrl) {
    if (manifest && manifest.prelude) {
      var preludeUrl = chiUrl(manifest.prelude, manifestUrl);
      await loadIrepUrl(preludeUrl, "prelude", manifest, manifestUrl);
    }
    if (component.helper_chi) {
      var helperUrl = chiUrl(component.helper_chi, manifestUrl);
      await loadIrepUrl(helperUrl, "helpers:" + component.helper_chi, manifest, manifestUrl);
    }
    var url = chiUrl(component, manifestUrl);
    return loadIrepUrl(url, component.class_name || component.tag_name, manifest, manifestUrl);
  }

  function syncElementAttribute(module, instance, name, value) {
    if (!module || typeof module._mochi_set_ivar_string !== "function") return false;
    if (!name || name.indexOf("data-mochi-") === 0 || name.indexOf("on") === 0) return false;
    var ivarName = name.replace(/-/g, "_");
    var strVal = value === null || value === undefined ? "" : String(value);
    return withUtf8(module, ivarName, function (nPtr, nLen) {
      return withUtf8(module, strVal, function (vPtr, vLen) {
        return module._mochi_set_ivar_string(instance, nPtr, nLen, vPtr, vLen) === 0;
      });
    });
  }

  function syncAllElementAttributes(module, instance, element) {
    if (!element || !element.attributes) return;
    for (var i = 0; i < element.attributes.length; i++) {
      var attr = element.attributes[i];
      syncElementAttribute(module, instance, attr.name, attr.value);
    }
  }

  // Drops host work produced by a mount attempt that is being rolled back. The
  // outboxes are drained after every completed entry, so during a synchronous
  // mount failure their contents belong to the failed instance.
  function discardHostOutboxes(module) {
    if (!module) return;
    try {
      if (typeof module._mochi_fetch_outbox_clear === "function") module._mochi_fetch_outbox_clear();
    } catch (error) {}
    try {
      if (typeof module._mochi_emit_outbox_clear === "function") module._mochi_emit_outbox_clear();
    } catch (error) {}
  }

  // Removes one instance's VM bindings and component root. Returns an Error on
  // failure so callers can report cleanup problems without masking the original
  // mount or unmount error.
  function disposeVmInstance(module, instance) {
    if (!module || instance === null || instance === undefined) {
      return new Error("mochi-loader: missing VM instance");
    }
    if (typeof module._mochi_unmount_component !== "function") {
      return new Error("mochi-loader: runtime does not support component disposal");
    }
    var result = module._mochi_unmount_component(instance);
    if (result !== 0) {
      return new Error("mochi-loader: component disposal failed: " + lastError(module));
    }
    return null;
  }

  // A mount is one transaction: instance creation, attribute sync, binding
  // registration, then the mounted hook. Any failure removes everything the
  // transaction created and rethrows the original error.
  async function mountInstance(component, manifest, manifestUrl, element, mountToken) {
    var module = await loadComponentClass(component, manifest, manifestUrl);

    // A final removal during the class download must not create a VM component
    // that only gets torn down later. A same-turn move has already reconnected
    // (and cancelled disposal) by the time the download settles.
    if (mountToken !== element._mochiMountToken || element._mochiDisconnected ||
        !element.isConnected) {
      return { cancelled: true, mountToken: mountToken };
    }

    var instance;

    withUtf8(module, component.class_name, function (pointer, length) {
      instance = module._mochi_mount_component(pointer, length);
    });

    if (instance === 0 || instance === 0n) {
      throw new Error("mochi-loader: mount failed for " + component.class_name + ": " + lastError(module));
    }

    var mountedStarted = false;
    try {
      syncAllElementAttributes(module, instance, element);

      flattenBindings(component.bindings).forEach(function (binding) {
        var symbol = intern(module, binding.getter_sym);
        if (module._mochi_register_binding(instance, binding.id, symbol) !== 0) {
          throw new Error("mochi-loader: binding registration failed for " +
            binding.getter_sym + ": " + lastError(module));
        }
      });

      if (hasMethod(module, instance, "mounted")) {
        mountedStarted = true;
        var mounted = intern(module, "mounted");
        if (module._mochi_dispatch_event(instance, mounted) !== 1) {
          throw new Error("mochi-loader: mounted dispatch failed for " +
            component.class_name + ": " + lastError(module));
        }
      }

      return { module: module, instance: instance, mountToken: mountToken };
    } catch (error) {
      if (mountedStarted) {
        // The component reached `mounted`, so give its `unmounted` hook one
        // chance to reverse partial Ruby-side setup before the registrations go.
        try {
          if (hasMethod(module, instance, "unmounted")) {
            module._mochi_dispatch_event(instance, intern(module, "unmounted"));
          }
        } catch (hookError) {
          console.error("[mochi] " + component.tag_name + " rollback unmounted failed", hookError);
        }
      }
      discardHostOutboxes(module);
      var cleanupError = disposeVmInstance(module, instance);
      if (cleanupError) {
        console.error("[mochi] " + component.tag_name + " rollback cleanup failed", cleanupError);
      }
      throw error;
    }
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

  function findEachContexts(target, root) {
    var nearest = null;
    var node = target;
    while (node && node !== root) {
      if (node.__mochiEachContext) {
        nearest = node.__mochiEachContext;
        break;
      }
      node = node.parentNode;
    }
    if (!nearest) return [];

    var contexts = [];
    var context = nearest;
    while (context) {
      contexts.unshift(context);
      context = context.parent;
    }
    return contexts;
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

  // Ruby expressions used as top-level event arguments are resolved from
  // cached binding values. List row arguments are compiled into Ruby wrappers
  // and never travel as expression text.
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

  function bindingRange(binding) {
    if (typeof binding.template_start !== "number" ||
        typeof binding.template_end !== "number" ||
        binding.template_end <= binding.template_start) {
      return null;
    }
    return { id: binding.id, start: binding.template_start, end: binding.template_end };
  }

  function addBindingEntry(state, binding) {
    if (state.ids.indexOf(binding.id) !== -1) return;
    state.ids.push(binding.id);
    var range = bindingRange(binding);
    if (range) state.entries.push(range);
  }

  // Compiler ranges are UTF-8 byte offsets. JavaScript strings index by
  // UTF-16 code unit, so literals such as the private-use brace escapes and
  // any non-ASCII user text need translating before `slice`.
  function byteOffsetToIndex(text, target) {
    var bytes = 0;
    var index = 0;
    while (index < text.length && bytes < target) {
      var code = text.codePointAt(index);
      if (code <= 0x7f) {
        bytes += 1;
      } else if (code <= 0x7ff) {
        bytes += 2;
      } else if (code <= 0xffff) {
        bytes += 3;
      } else {
        bytes += 4;
      }
      index += code > 0xffff ? 2 : 1;
    }
    return index;
  }

  function entryRange(state, entry) {
    return {
      id: entry.id,
      start: byteOffsetToIndex(state.template, entry.start),
      end: byteOffsetToIndex(state.template, entry.end)
    };
  }

  function substitute(state, values) {
    var template = String(state.template || "");
    var result = "";

    // The compiler records the exact byte range of every placeholder. Using
    // those ranges avoids guessing again in the browser and keeps nested
    // braces, quoted braces, and literal `{{...}}` text intact.
    if (state.entries.length === state.ids.length) {
      var entries = state.entries.map(function (entry) {
        return entryRange(state, entry);
      }).sort(function (left, right) {
        return left.start - right.start;
      });
      var cursor = 0;
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (entry.start < cursor) continue;
        result += template.slice(cursor, entry.start);
        if (Object.prototype.hasOwnProperty.call(values, entry.id)) {
          result += values[entry.id];
        } else {
          result += template.slice(entry.start, entry.end);
        }
        cursor = entry.end;
      }
      result += template.slice(cursor);
      return unescapeBraces(result);
    }

    var index = 0;
    result = template.replace(/\{([^}]+)\}/g, function (match) {
      var id = state.ids[index++];
      if (id === undefined || !Object.prototype.hasOwnProperty.call(values, id)) return match;
      return values[id];
    });
    return unescapeBraces(result);
  }

  function textBindingState(target, binding) {
    if (!target.__mochiText) {
      target.__mochiText = {
        template: binding.template_text || target.textContent || "",
        ids: [],
        entries: [],
        values: {}
      };
    }
    addBindingEntry(target.__mochiText, binding);
    return target.__mochiText;
  }

  function attrBindingState(target, binding) {
    if (!target.__mochiAttrs) target.__mochiAttrs = {};
    var name = binding.attr_name;
    if (!target.__mochiAttrs[name]) {
      target.__mochiAttrs[name] = {
        template: binding.template_text || "",
        ids: [],
        entries: [],
        values: {}
      };
    }
    var state = target.__mochiAttrs[name];
    addBindingEntry(state, binding);
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
    target.textContent = substitute(state, state.values);
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
    var nextValue = substitute(state, state.values);
    var isSinglePlaceholder = false;
    if (state.entries.length === 1) {
      var entry = entryRange(state, state.entries[0]);
      isSinglePlaceholder = state.template.slice(0, entry.start).trim() === "" &&
        state.template.slice(entry.end).trim() === "";
    } else if (state.entries.length === 0) {
      isSinglePlaceholder = state.ids.length === 1 && /^\s*\{[^}]+\}\s*$/.test(state.template);
    }
    if ((isSinglePlaceholder && (value === "" || value === "false")) || nextValue === "") {
      target.removeAttribute(binding.attr_name);
    } else {
      target.setAttribute(binding.attr_name, nextValue);
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
      applyEachPatch(element, target, binding, value);
    }
  }

  function itemKey(item, index) {
    if (item && typeof item === "object") {
      if (item.key !== undefined && item.key !== null) return String(item.key);
      if (item.id !== undefined && item.id !== null) return String(item.id);
    }
    return String(index);
  }

  function eachRowDescriptor(binding) {
    var rows = binding && binding.each_rows;
    if (!rows) {
      throw new Error("mochi-loader: each binding " + (binding && binding.id) +
        " has no compiled row descriptor");
    }
    return rows;
  }

  function escapeHtmlText(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function escapeHtmlAttribute(value) {
    return escapeHtmlText(value)
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function displayRowValue(value) {
    if (value === null || value === undefined) return "";
    if (typeof value === "string") return value;
    if (typeof value === "object") {
      try {
        return JSON.stringify(value);
      } catch (error) {
        return "";
      }
    }
    return String(value);
  }

  function renderRowTemplate(descriptor, values) {
    var template = descriptor.template || "";
    var bindings = descriptor.bindings || [];
    var rendered = template.replace(/\uE002(\d+)\uE003/g, function (match, rawSlot) {
      var slot = Number(rawSlot);
      var binding = null;
      for (var i = 0; i < bindings.length; i++) {
        if (bindings[i].slot === slot) {
          binding = bindings[i];
          break;
        }
      }
      var text = displayRowValue(Array.isArray(values) ? values[slot] : undefined);
      if (binding && binding.kind === "html") return text;
      if (binding && binding.kind === "attr") return escapeHtmlAttribute(text);
      return escapeHtmlText(text);
    });
    return unescapeBraces(rendered);
  }

  function rowSignature(row) {
    try {
      return JSON.stringify(row);
    } catch (error) {
      return "";
    }
  }

  function findEachAnchor(root, blockId) {
    var wanted = "mochi-each-" + blockId;
    var stack = [root];
    while (stack.length > 0) {
      var node = stack.pop();
      var children = node.childNodes || [];
      for (var i = 0; i < children.length; i++) {
        var child = children[i];
        if (child.nodeType === 8 && child.nodeValue === wanted) return child;
        if (child.childNodes && child.childNodes.length > 0) stack.push(child);
      }
    }
    return null;
  }

  function buildEachRow(element, descriptor, row, index, parentContext) {
    if (!Array.isArray(row) || row.length < 2) {
      throw new Error("mochi-loader: invalid list row for binding descriptor " + descriptor.id +
        " at index " + index);
    }

    var item = row[0];
    var values = row[1] || [];
    var children = row[2] || [];
    var html = renderRowTemplate(descriptor, values);
    var bindings = descriptor.bindings || [];
    var childDescriptors = descriptor.children || [];
    if (bindings.length === 0 && childDescriptors.length === 0 &&
        descriptor.template.indexOf("\uE002") === -1) {
      if (item && typeof item === "object" && typeof item.html === "string") {
        html = item.html;
      } else if (typeof item === "string") {
        html = item;
      }
    }

    var fragment = fragmentFor(html);
    var outerNodes = Array.from(fragment.childNodes);
    var context = {
      blockId: descriptor.id,
      item: item,
      index: index,
      parent: parentContext || null
    };
    outerNodes.forEach(function (node) {
      if (node.nodeType === 1) node.__mochiEachContext = context;
    });

    childDescriptors.forEach(function (child, childIndex) {
      var anchor = findEachAnchor(fragment, child.id);
      if (!anchor) {
        throw new Error("mochi-loader: missing nested list anchor " + child.id +
          " for binding descriptor " + descriptor.id);
      }
      var childRows = children[childIndex] || [];
      if (!Array.isArray(childRows)) {
        throw new Error("mochi-loader: nested list rows must be an array for binding descriptor " +
          child.id);
      }
      childRows.forEach(function (childRow, childRowIndex) {
        var built = buildEachRow(element, child, childRow, childRowIndex, context);
        built.nodes.forEach(function (node) {
          anchor.parentNode.insertBefore(node, anchor);
        });
      });
      anchor.parentNode.removeChild(anchor);
    });

    return {
      html: html,
      signature: rowSignature(row),
      nodes: Array.from(fragment.childNodes),
      context: context,
      contextNodes: outerNodes.filter(function (node) { return node.nodeType === 1; })
    };
  }

  function entryFollows(entry, cursor) {
    if (entry.nodes.length === 0) return true;
    if (entry.nodes[0].previousSibling !== cursor) return false;
    for (var i = 1; i < entry.nodes.length; i++) {
      if (entry.nodes[i].previousSibling !== entry.nodes[i - 1]) return false;
    }
    return true;
  }

  function applyEachPatch(element, target, binding, value) {
    var descriptor = eachRowDescriptor(binding);
    var rows;
    if (!value) {
      rows = [];
    } else {
      try {
        rows = JSON.parse(value);
      } catch (error) {
        throw new Error("mochi-loader: invalid each patch for binding " + binding.id);
      }
      if (!Array.isArray(rows)) {
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

    rows.forEach(function (row, index) {
      if (!Array.isArray(row) || row.length < 2) {
        throw new Error("mochi-loader: invalid list row for binding " + binding.id +
          " at index " + index);
      }
      var item = row[0];
      var key = itemKey(item, index);
      var signature = rowSignature(row);
      var entry = previous.get(key);
      if (!entry || entry.signature !== signature) {
        entry = buildEachRow(element, descriptor, row, index);
      } else {
        entry.context.item = item;
        entry.context.index = index;
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
    if (!element || element._mochiDisconnected || element._mochiUnmounted) return;
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
        this._mochiAttrObserver = null;
        this._mochiDisconnected = false;
        this._mochiDisposalScheduled = false;
        this._mochiUnmounted = false;
        this._mochiMountState = "idle";
        this._mochiMountToken = 0;
        this._mochiEventsAttached = false;
      }

      // Lifecycle contract:
      // - A DOM move runs disconnectedCallback then connectedCallback in the
      //   same reaction turn. Disposal waits one microtask, so the reconnect
      //   cancels it and the VM instance, bindings, timers, attribute observer,
      //   and event listeners survive unchanged. Ruby state is not recreated.
      // - A removal that remains disconnected through that microtask disposes
      //   once, running unmounted. Reinserting the element afterwards builds a
      //   new shadow tree and mounts a fresh VM instance from initial Ruby
      //   state, reusing only the static template and stylesheet.
      // - Removing the element during the asynchronous class download cancels
      //   the pending mount before any VM instance exists, so a detached tree
      //   never receives patches or leaves a ghost registration behind.
      connectedCallback() {
        ensureActionRouter();
        this._mochiDisposalScheduled = false;
        this._mochiDisconnected = false;
        if (this._mochiMountState === "mounting" || this._mochiMountState === "mounted") return;
        if (this.shadowRoot && this._mochiMountState === "idle") return;
        this._beginMount();
      }

      _beginMount() {
        var root = this.shadowRoot;
        if (!root) {
          root = this.attachShadow({ mode: "open" });
        } else {
          while (root.firstChild) root.removeChild(root.firstChild);
        }
        if (this._mochiAttrObserver) {
          this._mochiAttrObserver.disconnect();
          this._mochiAttrObserver = null;
        }

        this._mochiMountState = "mounting";
        this._mochiDisconnected = false;
        this._mochiDisposalScheduled = false;
        this._mochiUnmounted = false;
        this._mochiModule = null;
        this._mochiInstance = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.bindingData = {};
        allBindings.forEach(function (binding) {
          this.bindingData[binding.id] = binding;
        }, this);
        this.refs = this.bindingTargets;
        this._mochiMountToken = ++state.nextMountToken;
        var mountToken = this._mochiMountToken;

        var style = global.document.createElement("style");
        style.textContent = component.css || "";
        root.appendChild(style);

        var fragment = template.content.cloneNode(true);
        this._resolveBindings(fragment);
        root.appendChild(fragment);
        // The retained shadow root outlives every mount, so one delegated
        // listener per event serves all lifecycles of this element.
        if (!this._mochiEventsAttached) {
          this._attachEvents(root);
          this._mochiEventsAttached = true;
        }

        var element = this;
        this._mochiReady = mountInstance(component, state.manifest, manifestUrl, element, mountToken)
          .then(function (mounted) {
            if (mounted.cancelled) {
              element._settleCancelledMount(mountToken);
              return mounted;
            }
            if (mounted.mountToken !== element._mochiMountToken) {
              var staleError = disposeVmInstance(mounted.module, mounted.instance);
              if (staleError) {
                console.error("[mochi] " + tag + " stale mount cleanup failed", staleError);
              }
              return mounted;
            }

            element._mochiModule = mounted.module;
            element._mochiInstance = mounted.instance;

            if (element._mochiDisconnected || element._mochiUnmounted) {
              element._unmount(mounted.module, mounted.instance, mounted.mountToken);
              return mounted;
            }

            try {
              // The first binding flush is part of the mount transaction. A
              // failing getter (unknown method, arity) disposes the instance
              // and runs unmounted instead of leaving a ghost registration.
              element._mochiMountState = "mounted";
              state.elements.set(String(mounted.instance), element);
              state.unmountedInstances.delete(String(mounted.instance));
              element._observeAttributes(mounted.module, mounted.instance);
              applyPatches(element, mounted.module);
              drainEmits(mounted.module);
              drainFetches(mounted.module);
            } catch (error) {
              element._unmount(mounted.module, mounted.instance, mounted.mountToken);
              throw error;
            }
            return mounted;
          }).catch(function (error) {
            if (mountToken === element._mochiMountToken) {
              element._mochiMountState = "failed";
              element.mochiError = error;
            }
            console.error("[mochi] " + tag + " mount failed", error);
            throw error;
          });
      }

      _observeAttributes(module, instance) {
        if (typeof global.MutationObserver !== "function") return;
        // One observer per active lifecycle. A fresh mount replaces the
        // previous observer even if an earlier teardown failed.
        if (this._mochiAttrObserver) {
          this._mochiAttrObserver.disconnect();
          this._mochiAttrObserver = null;
        }
        var element = this;
        this._mochiAttrObserver = new global.MutationObserver(function (mutations) {
          if (element._mochiDisconnected || element._mochiUnmounted) return;
          var changed = false;
          for (var i = 0; i < mutations.length; i++) {
            var attrName = mutations[i].attributeName;
            if (!attrName) continue;
            if (syncElementAttribute(module, instance, attrName, element.getAttribute(attrName))) {
              changed = true;
            }
          }
          if (changed) {
            applyPatches(element, module);
            drainEmits(module);
            drainFetches(module);
          }
        });
        this._mochiAttrObserver.observe(this, { attributes: true });
      }

      disconnectedCallback() {
        this._mochiDisconnected = true;
        this._scheduleDisposal();
      }

      _scheduleDisposal() {
        if (this._mochiDisposalScheduled || this._mochiUnmounted) return;
        this._mochiDisposalScheduled = true;
        var element = this;
        deferDisposal(function () {
          element._flushScheduledDisposal();
        });
      }

      _flushScheduledDisposal() {
        if (!this._mochiDisposalScheduled) return;
        if (!this._mochiDisconnected || this.isConnected) {
          this._mochiDisposalScheduled = false;
          if (this.isConnected) this._mochiDisconnected = false;
          return;
        }
        if (this._mochiMountState === "unmounted") {
          this._mochiDisposalScheduled = false;
          return;
        }
        if (this._mochiMountState === "failed") {
          this._mochiDisposalScheduled = false;
          if (this._mochiModule && this._mochiInstance !== null && this._mochiInstance !== undefined) {
            this._unmount(this._mochiModule, this._mochiInstance, this._mochiMountToken);
            this._mochiMountState = "failed";
          }
          return;
        }
        var element = this;
        var ready = this._mochiReady;
        if (!ready) {
          this._finishScheduledDisposal();
          return;
        }
        ready.then(function () {
          element._finishScheduledDisposal();
        }, function () {
          // The failed mount already rolled back its VM registrations. Keep the
          // failed state so a later reconnect retries a complete mount.
          element._mochiDisposalScheduled = false;
        });
      }

      _finishScheduledDisposal() {
        if (!this._mochiDisposalScheduled) return;
        if (!this._mochiDisconnected || this.isConnected) {
          this._mochiDisposalScheduled = false;
          if (this.isConnected) this._mochiDisconnected = false;
          return;
        }
        this._mochiDisposalScheduled = false;
        if (this._mochiUnmounted) return;
        if (this._mochiModule && this._mochiInstance !== null && this._mochiInstance !== undefined) {
          this._unmount(this._mochiModule, this._mochiInstance, this._mochiMountToken);
          return;
        }
        this._markUnmountedWithoutInstance();
      }

      // A mount cancelled before instance creation still has to leave the
      // element ready for a later fresh mount. If it reconnected while the
      // download was settling, start the mount again with the current token.
      _settleCancelledMount(mountToken) {
        if (mountToken !== this._mochiMountToken) return;
        if (this.isConnected && !this._mochiDisconnected) {
          this._beginMount();
          return;
        }
        this._markUnmountedWithoutInstance();
      }

      _markUnmountedWithoutInstance() {
        if (this._mochiUnmounted) return;
        this._mochiUnmounted = true;
        this._mochiMountState = "unmounted";
        this._mochiDisposalScheduled = false;
        if (this._mochiAttrObserver) {
          this._mochiAttrObserver.disconnect();
          this._mochiAttrObserver = null;
        }
        this._mochiModule = null;
        this._mochiInstance = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.refs = this.bindingTargets;
      }

      // Disposal order: stop routing, cancel the instance's pending host work,
      // run the unmounted hook once, flush host commands, then always remove the
      // VM registrations. The DOM/binding caches clear last, after the hook can
      // no longer read them, and a failed hook never skips VM cleanup.
      _unmount(module, instance, mountToken) {
        if (this._mochiUnmounted) return;
        if (mountToken !== undefined && mountToken !== this._mochiMountToken) return;
        this._mochiDisposalScheduled = false;
        this._mochiUnmounted = true;
        this._mochiMountState = "unmounted";

        if (this._mochiAttrObserver) {
          this._mochiAttrObserver.disconnect();
          this._mochiAttrObserver = null;
        }

        var key = String(instance);
        state.unmountedInstances.add(key);
        state.pendingFetches = state.pendingFetches.filter(function (request) {
          return String(request.instance) !== key;
        });
        state.timers.forEach(function (record, timerId) {
          if (record.instance === key) clearTimerEntry(timerId);
        });
        if (state.elements.get(key) === this) state.elements.delete(key);

        try {
          if (hasMethod(module, instance, "unmounted")) {
            var symbol = intern(module, "unmounted");
            if (module._mochi_dispatch_event(instance, symbol) !== 1) {
              throw new Error("mochi-loader: unmounted dispatch failed for " + tag + ": " + lastError(module));
            }
          }
        } catch (error) {
          this.mochiError = error;
          console.error("[mochi] " + tag + " unmount failed", error);
        }

        // Host drains run even when the hook failed. Consuming the fetch outbox
        // while the instance is still marked unmounted prevents a later mount
        // from inheriting the old handle's requests.
        try {
          drainEmits(module);
        } catch (error) {
          this.mochiError = this.mochiError || error;
          console.error("[mochi] " + tag + " unmount emit drain failed", error);
        }
        try {
          drainFetches(module);
        } catch (error) {
          this.mochiError = this.mochiError || error;
          console.error("[mochi] " + tag + " unmount fetch drain failed", error);
        }

        var disposeError = disposeVmInstance(module, instance);
        if (disposeError) {
          this.mochiError = this.mochiError || disposeError;
          console.error("[mochi] " + tag + " VM cleanup failed", disposeError);
        }

        this._mochiModule = null;
        this._mochiInstance = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.refs = this.bindingTargets;
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
        var eachContexts = findEachContexts(target, this.shadowRoot);
        var nearestEachContext = eachContexts.length > 0 ? eachContexts[eachContexts.length - 1] : null;
        if (nearestEachContext) {
          payload.item = nearestEachContext.item;
          payload.index = nearestEachContext.index;
        }
        var descriptors;

        try {
          descriptors = eventArguments(target, event.type);
        } catch (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " event failed", error);
          return;
        }

        var mountToken = this._mochiMountToken;
        this._mochiReady.then(function (mounted) {
          if (element._mochiDisconnected || element._mochiUnmounted ||
              mounted.mountToken !== element._mochiMountToken ||
              mountToken !== element._mochiMountToken) {
            return;
          }
          var symbol = intern(mounted.module, method);
          var dispatched;

          if (method.indexOf("__mochi_each_") === 0) {
            if (eachContexts.length === 0) {
              throw new Error("mochi-loader: list row event " + method + " has no row context");
            }
            var rowArgs = [];
            eachContexts.forEach(function (context) {
              rowArgs.push(context.item);
              rowArgs.push(context.index);
            });
            rowArgs.push(payload);
            dispatched = dispatchEventArgs(mounted.module, mounted.instance, symbol, rowArgs);
          } else if (descriptors.length > 0) {
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
          drainFetches(mounted.module);
        }).catch(function (error) {
          element.mochiError = error;
          console.error("[mochi] " + tag + " event failed", error);
        });
      }

      _dispatchAction(detail) {
        var action = typeof detail === "string" ? detail : detail && detail.action;
        if (!action || this._mochiDisconnected || this._mochiUnmounted) return;

        var target = detail && typeof detail === "object" ? detail.target : null;
        var component = this._mochiComponent || {};
        if (target) {
          var tagName = String(component.tag_name || "").toLowerCase();
          if (tagName !== String(target).toLowerCase()) return;
        }

        var module = this._mochiModule;
        var instance = this._mochiInstance;
        if (!module || instance === null || instance === undefined) return;
        if (state.elements.get(String(instance)) !== this) return;

        try {
          if (!actionSupported(module, this, action)) return;

          var symbol = intern(module, action);
          var hasPayload = false;
          if (detail && typeof detail === "object") {
            hasPayload = detail.hasPayload !== undefined
              ? Boolean(detail.hasPayload)
              : detail.payload !== undefined && detail.payload !== null;
          }
          var payload = hasPayload ? detail.payload : null;
          var dispatched;
          if (requiredArgumentCount(module, instance, symbol) === 1) {
            dispatched = dispatchEventArgs(module, instance, symbol, [payload]);
          } else {
            dispatched = module._mochi_dispatch_event(instance, symbol) === 1;
          }
          if (!dispatched) {
            throw new Error("mochi-loader: action dispatch failed for " + action + ": " + lastError(module));
          }
          if (!this._mochiDisconnected && !this._mochiUnmounted) {
            applyPatches(this, module);
            drainEmits(module);
            drainFetches(module);
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

  // Small inspection surface for lifetime tests. VM counts come from the
  // bridge; the rest describe loader bookkeeping that must also drain.
  function debugStats() {
    var module = state.activeModule;
    return {
      bindings: module && typeof module._mochi_binding_count === "function"
        ? Number(module._mochi_binding_count()) : -1,
      components: module && typeof module._mochi_component_count === "function"
        ? Number(module._mochi_component_count()) : -1,
      elements: state.elements.size,
      timers: state.timers.size,
      pendingFetches: state.pendingFetches.length,
      unmountedInstances: state.unmountedInstances.size,
      stateObjects: module && typeof module._mochi_state_object_count === "function"
        ? Number(module._mochi_state_object_count()) : -1,
      stateAllocated: module && typeof module._mochi_state_allocated_count === "function"
        ? Number(module._mochi_state_allocated_count()) : -1,
      stateFreeBytes: module && typeof module._mochi_state_free_bytes === "function"
        ? Number(module._mochi_state_free_bytes()) : -1
    };
  }

  var loader = {
    boot: boot,
    moduleFactory: null,
    applyPatches: applyPatches,
    debugStats: debugStats,
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
