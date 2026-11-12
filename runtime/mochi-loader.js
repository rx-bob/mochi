// mochi-loader.js - static Custom Element + Shadow DOM loader for mochi-gvm.
(function (global) {
  "use strict";

  var RITE_HEADER = new Uint8Array([0x52, 0x49, 0x54, 0x45, 0x30, 0x34, 0x30, 0x30, 0x00, 0x00]);
  var COMPONENT_DIR = "components/";
  var DEFAULT_MANIFEST = "mochi-manifest.json";
  var MANIFEST_SCHEMA_VERSION = 1;
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
    hostModulePromises: new Map(),
    internCache: new Map(),
    tags: new Set(),
    elements: new Map(),
    pendingFetches: [],
    timers: new Map(),
    unmountedInstances: new Set(),
    nextMountToken: 0,
    actionRouterInstalled: false,
    actionSupportCache: new Map(),
    styleSheetCache: new Map(),
    localStyleSheetCache: new WeakMap(),
    focusTrapDocument: null,
    lastEventTarget: null
  };

  var focusStacks = new WeakMap();

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

  // The VM marks a nil binding result with a private-use code point. Nil and an
  // empty string stay distinct: nil removes a single-placeholder attribute,
  // while an empty string keeps a textual attribute present and empty.
  var NIL_BINDING_TEXT = "\uE004";

  function nilBinding(value) {
    return value === NIL_BINDING_TEXT;
  }

  function displayBindingValue(value) {
    return nilBinding(value) || value === null || value === undefined ? "" : String(value);
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
    if (!module || !module._mochi_last_error_offset || !module._mochi_last_error_len) return "";
    var offset = module._mochi_last_error_offset();
    var length = module._mochi_last_error_len();
    if (!offset || length <= 0) return "";
    return decode(module.HEAPU8.subarray(offset, offset + length));
  }

  // One failure shape for every runtime entry point. The VM text is kept even
  // when the JS layer already has an error, because only the VM knows which
  // Ruby method failed.
  function methodFromError(error, fallback) {
    var match = error && error.message ? /#([A-Za-z_][A-Za-z0-9_?!]*)/.exec(error.message) : null;
    return match ? match[1] : fallback;
  }

  function bindingForMethod(element, method) {
    if (!element || !element.bindingData || !method) return null;
    var ids = Object.keys(element.bindingData);
    for (var i = 0; i < ids.length; i += 1) {
      var binding = element.bindingData[ids[i]];
      if (binding && (binding.getter_sym === method || binding.setter_sym === method)) {
        return binding;
      }
    }
    return null;
  }

  function describeError(component, phase, method, error, module, element) {
    var detail = error && error.message ? error.message : String(error || "");
    var vmText = lastError(module);
    if (vmText && detail.indexOf(vmText) === -1) {
      detail = detail ? detail + ": " + vmText : vmText;
    }
    if (!detail) detail = phase + " failed";
    var source = component && component.source;
    var line = source && source.line;
    if (source && component.methods && method) {
      var mapped = Number(component.methods[method]);
      if (mapped > 0) line = mapped;
    }
    // Generated getters are not user methods. Point at the template
    // expression that produced the getter instead of the class declaration.
    var binding = bindingForMethod(element, method);
    if (binding && binding.source && binding.source.file) {
      source = binding.source;
      line = binding.source.line;
    }
    // A declared prop or child event carries its own declaration site. Point
    // the report there instead of at the component class or handler.
    var context = error && error.mochiContext;
    var declarationSource = context && (context.propSource || context.eventSource);
    if (declarationSource && declarationSource.file) {
      source = declarationSource;
      line = declarationSource.line;
    }
    var location = source && source.file
      ? source.file + (line > 0 ? ":" + line : "")
      : "";
    return {
      phase: phase,
      tagName: component && component.tag_name || "",
      className: component && component.class_name || "",
      method: method || "",
      source: location,
      vmText: vmText,
      message: location ? detail + " at " + location : detail
    };
  }

  function reportError(element, phase, method, error, module, context) {
    var component = element && element._mochiComponent;
    var info = describeError(component, phase, method, error, module, element);
    if (context) {
      if (context.attribute !== undefined) info.attribute = context.attribute;
      if (context.property !== undefined) info.property = context.property;
    }
    if (error && error.mochiContext) {
      Object.keys(error.mochiContext).forEach(function (key) {
        if (key !== "propSource" && key !== "eventSource") {
          info[key] = error.mochiContext[key];
        }
      });
    }
    var reported = error instanceof Error ? error : new Error(info.message);
    try {
      reported.message = info.message;
    } catch (_) {
      reported = new Error(info.message);
    }
    reported.mochi = info;
    if (element) element.mochiError = reported;
    console.error("[mochi] " + (info.tagName || "loader") + " " + phase + " failed", reported);
    try {
      if (global.document && typeof global.CustomEvent === "function") {
        global.document.dispatchEvent(new global.CustomEvent("mochi:error", { detail: info }));
      }
    } catch (dispatchError) {
      console.error("[mochi] error event dispatch failed", dispatchError);
    }
    if (typeof loader !== "undefined" && typeof loader.onError === "function") {
      try {
        loader.onError(info, reported);
      } catch (hookError) {
        console.error("[mochi] onError hook failed", hookError);
      }
    }
    return reported;
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
    if (typeof parsed.__child_event === "string") return parsed;
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
      reportError(element, "fetch", request && request.callback, error, module);
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

  function reportFocusError(element, reference, detail, module) {
    var error = new Error("mochi-loader: " + detail);
    error.mochiContext = { reference: reference || "" };
    reportError(element, "focus", reference || "focus", error, module);
  }

  function handleHostCommand(module, entry) {
    var hostKind = entry.__host;
    if (hostKind === "storage_set") {
      try {
        if (global.localStorage && typeof entry.key === "string") {
          global.localStorage.setItem(entry.key, String(entry.value !== undefined ? entry.value : ""));
        }
      } catch (error) {
        reportError(null, "storage", "storage_set", error);
      }
      return;
    }
    if (hostKind === "storage_remove") {
      try {
        if (global.localStorage && typeof entry.key === "string") {
          global.localStorage.removeItem(entry.key);
        }
      } catch (error) {
        reportError(null, "storage", "storage_remove", error);
      }
      return;
    }
    if (hostKind === "set_route") {
      var path = typeof entry.path === "string" ? entry.path : "/";
      try {
        if (global.history && typeof global.history.pushState === "function") {
          var targetUrl = path.charAt(0) === "#" || path.charAt(0) === "/" ? path : "#" + path;
          global.history.pushState(null, "", targetUrl);
        }
      } catch (error) {
        reportError(null, "route", "set_route", error);
      }
      notifyRouteChange(path);
      return;
    }
    if (hostKind === "focus") {
      var focusHost = state.elements.get(String(entry.instance || ""));
      var refName = typeof entry.name === "string" ? entry.name : "";
      if (!focusHost || focusHost._mochiDisconnected || focusHost._mochiUnmounted ||
          !focusHost.isConnected) {
        reportFocusError(focusHost, refName, "focus target component is not mounted", module);
        return;
      }
      if (!refName) {
        reportFocusError(focusHost, refName, "focus requires a named ref", module);
        return;
      }
      var focusTarget = findNamedRef(focusHost, refName);
      if (!focusTarget || !focusTarget.isConnected) {
        reportFocusError(focusHost, refName, "no element with ref \"" + refName + "\"", module);
        return;
      }
      rememberFocus(focusHost, focusTarget);
      if (!focusNode(focusTarget)) {
        reportFocusError(focusHost, refName, "element with ref \"" + refName + "\" is not focusable", module);
      }
      return;
    }
    if (hostKind === "restore_focus") {
      var restoreHost = state.elements.get(String(entry.instance || ""));
      if (!restoreHost || restoreHost._mochiDisconnected || restoreHost._mochiUnmounted ||
          !restoreHost.isConnected) {
        reportFocusError(restoreHost, "restore_focus", "focus target component is not mounted", module);
        return;
      }
      if (!restoreRememberedFocus(restoreHost)) {
        reportFocusError(restoreHost, "restore_focus", "no connected focus target to restore", module);
      }
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
          reportError(element, "timer", callbackName, error, module);
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

  function childEventDescriptor(component, eventName) {
    var emits = component && component.emits;
    if (!emits || !emits.length) return null;
    for (var i = 0; i < emits.length; i++) {
      if (emits[i] && emits[i].name === eventName) return emits[i];
    }
    return null;
  }

  function childEventError(eventName, descriptor, detail, field) {
    var error = new Error("mochi-loader: event \"" + eventName + "\" " + detail);
    error.mochiContext = { event: eventName };
    if (field) {
      error.mochiContext.payloadKey = field.name;
      error.mochiContext.eventType = field.type;
    }
    if (descriptor && descriptor.source && descriptor.source.file) {
      error.mochiContext.eventSource = {
        file: descriptor.source.file,
        line: Number(descriptor.source.line) || 0
      };
    }
    return error;
  }

  function eventValueKind(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    return typeof value;
  }

  function mochiNumberKind(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    var keys = Object.keys(value);
    if (keys.length !== 2 || keys.indexOf("__mochi_number") === -1 || keys.indexOf("value") === -1) {
      return null;
    }
    if (value.__mochi_number !== "i64" && value.__mochi_number !== "f64") return null;
    if (typeof value.value !== "string") return null;
    return value.__mochi_number;
  }

  function isMochiNumber(value) {
    return mochiNumberKind(value) !== null;
  }

  function mochiNumberText(value) {
    return isMochiNumber(value) ? value.value : "";
  }

  function integerTextInInt64(text) {
    if (!/^-?\d+$/.test(text)) return false;
    try {
      var value = BigInt(text);
      return value >= -(1n << 63n) && value <= (1n << 63n) - 1n;
    } catch (error) {
      return false;
    }
  }

  function integerTextIsSafe(text) {
    if (!/^-?\d+$/.test(text)) return false;
    try {
      var value = BigInt(text);
      return value >= -9007199254740991n && value <= 9007199254740991n;
    } catch (error) {
      return false;
    }
  }

  function floatTextIsValid(text) {
    if (text === "Infinity" || text === "-Infinity" || text === "NaN") return true;
    return /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) &&
      !isNaN(Number(text));
  }

  function mochiNumberIsValid(value) {
    var kind = mochiNumberKind(value);
    if (kind === "i64") return integerTextInInt64(value.value);
    if (kind === "f64") return floatTextIsValid(value.value);
    return false;
  }

  function integerTransportValue(text) {
    if (integerTextIsSafe(text)) return Number(text);
    return { __mochi_number: "i64", value: text };
  }

  function floatTransportValue(text) {
    return { __mochi_number: "f64", value: text };
  }

  function checkEventNumberRange(value, eventName, descriptor, field, integerField) {
    var kind = mochiNumberKind(value);
    if (kind !== null) {
      if (!mochiNumberIsValid(value) || (integerField && kind !== "i64")) {
        throw childEventError(
          eventName,
          descriptor,
          "payload field \"" + field.name + "\" contains an invalid or out-of-range " + kind + " number",
          field
        );
      }
      return;
    }
    if (typeof value === "number") {
      if (!Number.isFinite(value) ||
          (Number.isInteger(value) && !Number.isSafeInteger(value)) ||
          (integerField && !Number.isInteger(value))) {
        throw childEventError(
          eventName,
          descriptor,
          "payload field \"" + field.name + "\" contains a number that is not an exact " +
            (integerField ? "signed 64-bit integer" : "finite float"),
          field
        );
      }
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(function (item) {
        checkEventNumberRange(item, eventName, descriptor, field, false);
      });
      return;
    }
    if (value && typeof value === "object") {
      Object.keys(value).forEach(function (key) {
        checkEventNumberRange(value[key], eventName, descriptor, field, false);
      });
    }
  }

  function checkEventValue(value, eventName, descriptor, field) {
    var type = field.type;
    var valid = false;
    if (type === "string") {
      valid = typeof value === "string";
    } else if (type === "integer") {
      valid = (typeof value === "number" && Number.isInteger(value)) ||
        mochiNumberKind(value) === "i64";
      if (valid) checkEventNumberRange(value, eventName, descriptor, field, true);
    } else if (type === "float") {
      valid = (typeof value === "number" && Number.isFinite(value)) ||
        mochiNumberKind(value) === "f64" || mochiNumberKind(value) === "i64";
      if (valid) checkEventNumberRange(value, eventName, descriptor, field, false);
    } else if (type === "boolean") {
      valid = value === true || value === false;
    } else if (type === "array") {
      valid = Array.isArray(value);
      if (valid) checkEventNumberRange(value, eventName, descriptor, field, false);
    } else if (type === "hash") {
      valid = !!value && typeof value === "object" && !Array.isArray(value) &&
        mochiNumberKind(value) === null;
      if (valid) checkEventNumberRange(value, eventName, descriptor, field, false);
    }
    if (!valid) {
      throw childEventError(
        eventName,
        descriptor,
        "payload field \"" + field.name + "\" expects " + type +
          ", got " + eventValueKind(value),
        field
      );
    }
    if (type === "array" || type === "hash") {
      checkEventNumberRange(value, eventName, descriptor, field);
    }
  }

  function validateChildEventPayload(component, eventName, payload) {
    var descriptor = childEventDescriptor(component, eventName);
    if (!descriptor) {
      throw childEventError(
        eventName,
        null,
        "is not declared by this component"
      );
    }
    var body = payload === undefined || payload === null ? {} : payload;
    if (typeof body !== "object" || Array.isArray(body)) {
      throw childEventError(eventName, descriptor, "expects an object payload");
    }

    var fields = descriptor.payload || [];
    var known = Object.create(null);
    fields.forEach(function (field) {
      known[field.name] = field;
    });
    Object.keys(body).forEach(function (key) {
      if (!known[key]) {
        throw childEventError(
          eventName,
          descriptor,
          "does not declare payload field \"" + key + "\""
        );
      }
    });
    fields.forEach(function (field) {
      if (!Object.prototype.hasOwnProperty.call(body, field.name)) {
        throw childEventError(
          eventName,
          descriptor,
          "requires payload field \"" + field.name + "\"",
          field
        );
      }
      checkEventValue(body[field.name], eventName, descriptor, field);
    });
    return body;
  }

  // Delivers a child event to the exact mounted child that emitted it. The
  // resulting DOM CustomEvent bubbles through the parent's shadow root, so the
  // compiler-generated `data-mochi-<event>` binding on that child decides which
  // parent method runs. A stale line is dropped instead of reaching a
  // replacement that reused an instance slot.
  function deliverChildEvent(module, entry) {
    var eventName = entry.__child_event;
    if (!eventName) return false;
    var instanceKey = entry.instance === undefined || entry.instance === null
      ? ""
      : String(entry.instance);
    var child = instanceKey ? state.elements.get(instanceKey) : null;
    if (!child || child._mochiDisconnected || child._mochiUnmounted ||
        child._mochiInstance === null || child._mochiInstance === undefined ||
        String(child._mochiInstance) !== instanceKey ||
        state.unmountedInstances.has(instanceKey)) {
      return false;
    }

    var payload;
    try {
      payload = validateChildEventPayload(
        child._mochiComponent,
        eventName,
        entry.payload
      );
    } catch (error) {
      reportError(child, "event", eventName, error, child._mochiModule || module);
      return false;
    }

    try {
      // Keep the event inside the connected parent's shadow tree. A composed
      // event would also cross into ancestor shadow roots, where an unrelated
      // component listening for the same event name could route it again.
      var event = new global.CustomEvent(eventName, {
        bubbles: true,
        composed: false,
        detail: payload
      });
      event.__mochiChildEvent = true;
      child.dispatchEvent(event);
    } catch (error) {
      reportError(child, "event", eventName, error, child._mochiModule || module);
      return false;
    }
    return true;
  }

  // Drains Ruby `Mochi.emit`, `Mochi.emit_child`, and `Mochi.*` host calls.
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
      if (typeof entry.__child_event === "string") {
        deliverChildEvent(module, entry);
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

  // Optional host adapters must be registered before a component can call them
  // from initialize or its first binding. The manifest names the adapter; the
  // promise map keeps concurrent mounts to one request.
  function formatHostPath(manifest) {
    if (!manifest) return null;
    var capability = manifest.capabilities && manifest.capabilities.formatting;
    if (capability && capability.host) return capability.host;
    return manifest.format_host || null;
  }

  function ensureFormatHost(manifest, manifestUrl) {
    var host = formatHostPath(manifest);
    if (!host) return Promise.resolve();
    var url = absoluteUrl(host, manifestUrl);
    var existing = state.hostModulePromises.get(url);
    if (existing) return existing;

    var promise = loadRuntime(manifest, manifestUrl).then(function (module) {
      if (module.__mochiFormatHost) return module;
      if (global.MochiFormatHost) {
        module.__mochiFormatHost = global.MochiFormatHost;
        return module;
      }
      var load = loader.hostModuleFactory
        ? Promise.resolve(loader.hostModuleFactory(url))
        : loadScript(url);
      return load.then(function () {
        if (!global.MochiFormatHost || typeof global.MochiFormatHost.format !== "function") {
          throw new Error("formatting host did not register");
        }
        module.__mochiFormatHost = global.MochiFormatHost;
        return module;
      });
    }).catch(function (error) {
      state.hostModulePromises.delete(url);
      throw new Error("mochi-loader: failed to load formatting host " + url + ": " +
        (error && error.message ? error.message : String(error)));
    });

    state.hostModulePromises.set(url, promise);
    return promise;
  }

  function componentNeedsFormatting(component) {
    return component.formatting === true ||
      (Array.isArray(component.capabilities) && component.capabilities.indexOf("formatting") !== -1);
  }

  function loadPackage(id, manifest, manifestUrl, trail) {
    trail = trail || [];
    if (trail.indexOf(id) !== -1) {
      throw new Error("mochi-loader: package cycle at " + id);
    }

    var packages = manifest.packages || {};
    var descriptor = packages[id];
    if (!descriptor) {
      throw new Error("mochi-loader: missing package '" + id + "' in " + manifestUrl);
    }

    var next = trail.concat([id]);
    var dependencies = Array.isArray(descriptor.dependencies)
      ? descriptor.dependencies.slice().sort()
      : [];
    var chain = Promise.resolve();
    dependencies.forEach(function (dependency) {
      chain = chain.then(function () {
        return loadPackage(dependency, manifest, manifestUrl, next);
      });
    });

    return chain.then(function () {
      if (descriptor.kind === "capability") {
        if (id === "capability:formatting") return ensureFormatHost(manifest, manifestUrl);
        return null;
      }
      if (!descriptor.file) {
        throw new Error("mochi-loader: package '" + id + "' has no bytecode file");
      }
      return loadIrepUrl(chiUrl(descriptor.file, manifestUrl), id, manifest, manifestUrl);
    });
  }

  async function loadComponentClass(component, manifest, manifestUrl) {
    var needsFormatting = componentNeedsFormatting(component);
    if (needsFormatting) {
      if (!formatHostPath(manifest)) {
        throw new Error("mochi-loader: formatting capability requested by " +
          (component.tag_name || component.class_name) + " but the manifest has no host");
      }
      await ensureFormatHost(manifest, manifestUrl);
    }

    if (manifest && manifest.packages && (component.package || (Array.isArray(component.dependencies) && component.dependencies.length > 0))) {
      var dependencies = Array.isArray(component.dependencies)
        ? component.dependencies.slice().sort()
        : [];
      for (var i = 0; i < dependencies.length; i++) {
        await loadPackage(dependencies[i], manifest, manifestUrl, []);
      }
      var packageId = component.package || ("component:" + (component.tag_name || ""));
      await loadPackage(packageId, manifest, manifestUrl, []);
      return state.activeModule;
    }

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

  function attributeValueIsCurrent(element, name, value) {
    return !!(element && element._mochiAttributeValues) &&
      Object.prototype.hasOwnProperty.call(element._mochiAttributeValues, name) &&
      element._mochiAttributeValues[name] === value;
  }

  function rememberAttributeValue(element, name, value) {
    if (!element) return;
    if (!element._mochiAttributeValues) element._mochiAttributeValues = Object.create(null);
    element._mochiAttributeValues[name] = value;
  }

  function attributeNameForProp(name) {
    return String(name || "").replace(/_/g, "-");
  }

  function propDescriptorFor(component, attrName) {
    var props = component && component.props;
    if (!props || !props.length || !attrName) return null;
    var propName = String(attrName).replace(/-/g, "_");
    for (var i = 0; i < props.length; i++) {
      if (props[i] && props[i].name === propName) return props[i];
    }
    return null;
  }

  function hasDeclaredProps(component) {
    return !!(component && component.props && component.props.length);
  }

  // A single `{expression}` is a generated parent binding, not a literal.
  // Declared props wait for the first parent patch instead of mounting with
  // the placeholder text or failing a type check against it.
  function isBindingPlaceholder(text) {
    if (typeof text !== "string" || !/^\{[^{}]*\}$/.test(text)) return false;
    var inner = text.slice(1, -1).trim();
    // A quoted first character is a JSON object key, not a Ruby expression.
    return inner.length > 0 && inner[0] !== "\"" && inner[0] !== "'";
  }

  function propError(descriptor, detail, attribute) {
    var error = new Error("mochi-loader: prop \"" + descriptor.name + "\" " + detail);
    error.mochiContext = {
      attribute: attribute === undefined ? attributeNameForProp(descriptor.name) : attribute,
      property: descriptor.name,
      propType: descriptor.type
    };
    if (descriptor.source && descriptor.source.file) {
      error.mochiContext.propSource = {
        file: descriptor.source.file,
        line: Number(descriptor.source.line) || 0
      };
    }
    return error;
  }

  function checkPropNumberRange(value, descriptor, attribute) {
    if (mochiNumberKind(value) !== null) {
      if (!mochiNumberIsValid(value)) {
        throw propError(descriptor, "contains an invalid or out-of-range number", attribute);
      }
      return;
    }
    if (typeof value === "number") {
      if (!Number.isFinite(value) ||
          (Number.isInteger(value) && !Number.isSafeInteger(value))) {
        throw propError(descriptor, "contains a number that is not exactly representable", attribute);
      }
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(function (item) { checkPropNumberRange(item, descriptor, attribute); });
      return;
    }
    if (value && typeof value === "object") {
      Object.keys(value).forEach(function (key) {
        checkPropNumberRange(value[key], descriptor, attribute);
      });
    }
  }

  // HTML attribute text -> typed Ruby value. Strings stay strings, booleans
  // accept the HTML presence form, integers reject fractions and whitespace,
  // and collections require valid JSON of the declared shape. Anything else is
  // an explicit error instead of an ambiguous cast.
  function readDeclaredProp(descriptor, raw, attribute) {
    if (raw === null || raw === undefined) return { present: false, pending: false };
    var text = String(raw);
    // A JSON object literal also starts and ends with braces. Collections try
    // JSON first; every other type treats a single brace expression as a
    // parent binding that has not produced its first value yet.
    if (descriptor.type !== "array" && descriptor.type !== "hash" &&
        isBindingPlaceholder(text)) {
      return { present: false, pending: true };
    }

    if (descriptor.type === "string") {
      return { present: true, pending: false, value: text };
    }
    if (descriptor.type === "boolean") {
      if (text === "true" || text === "") {
        return { present: true, pending: false, value: true };
      }
      if (text === "false") {
        return { present: true, pending: false, value: false };
      }
      throw propError(descriptor, "expects a boolean (true or false), got \"" + text + "\"", attribute);
    }
    if (descriptor.type === "integer") {
      if (!/^-?\d+$/.test(text)) {
        throw propError(descriptor, "expects an integer, got \"" + text + "\"", attribute);
      }
      if (!integerTextInInt64(text)) {
        throw propError(descriptor, "integer is outside the signed 64-bit range", attribute);
      }
      return { present: true, pending: false, value: integerTransportValue(text) };
    }
    if (descriptor.type === "float") {
      if (!floatTextIsValid(text)) {
        throw propError(descriptor, "expects a float, got \"" + text + "\"", attribute);
      }
      return { present: true, pending: false, value: floatTransportValue(text) };
    }
    if (descriptor.type === "array" || descriptor.type === "hash") {
      var parsed;
      try {
        parsed = JSON.parse(text);
      } catch (parseError) {
        if (isBindingPlaceholder(text)) {
          return { present: false, pending: true };
        }
        throw propError(descriptor, "expects JSON " + descriptor.type + " text", attribute);
      }
      if (descriptor.type === "array") {
        if (!Array.isArray(parsed)) {
          throw propError(descriptor, "expects a JSON array", attribute);
        }
      } else if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw propError(descriptor, "expects a JSON object", attribute);
      }
      checkPropNumberRange(parsed, descriptor, attribute);
      return { present: true, pending: false, value: parsed };
    }
    throw propError(descriptor, "has unsupported declared type \"" + descriptor.type + "\"", attribute);
  }

  // Resolves all declared props before a mount allocates a VM instance.
  // Required inputs and type failures therefore abort with no partial mount.
  function resolveMountProps(component, element) {
    if (!hasDeclaredProps(component) || !element || !element.attributes) return null;
    var values = Object.create(null);
    var present = Object.create(null);
    var pending = Object.create(null);
    var rawValues = [];

    for (var i = 0; i < element.attributes.length; i++) {
      var attr = element.attributes[i];
      var descriptor = propDescriptorFor(component, attr.name);
      if (!descriptor) continue;
      var resolved = readDeclaredProp(descriptor, attr.value, attr.name);
      if (resolved.pending) {
        pending[descriptor.name] = true;
        continue;
      }
      present[descriptor.name] = resolved.present;
      if (resolved.present) values[descriptor.name] = resolved.value;
      rawValues.push({ name: attr.name, value: attr.value });
    }

    for (var p = 0; p < component.props.length; p++) {
      var prop = component.props[p];
      if (present[prop.name] || pending[prop.name]) continue;
      if (prop.required) {
        throw propError(prop, "is required but no attribute was provided", attributeNameForProp(prop.name));
      }
    }

    return { json: JSON.stringify(values), rawValues: rawValues, values: values };
  }

  // Collects one batch of changed declared props. The caller writes the whole
  // batch with one VM entry and then flushes once, so related inputs never
  // produce an intermediate render.
  function collectDeclaredPropUpdates(component, element, names) {
    if (!hasDeclaredProps(component) || !element || !element.attributes) return null;
    var filter = null;
    if (names) {
      filter = Object.create(null);
      names.forEach(function (name) { filter[name] = true; });
    }

    var updates = Object.create(null);
    var rawValues = [];
    var changed = false;
    var seen = Object.create(null);

    for (var i = 0; i < element.attributes.length; i++) {
      var attr = element.attributes[i];
      if (filter && !filter[attr.name]) continue;
      var descriptor = propDescriptorFor(component, attr.name);
      if (!descriptor) continue;
      seen[descriptor.name] = true;
      if (attributeValueIsCurrent(element, attr.name, attr.value)) continue;
      var resolved = readDeclaredProp(descriptor, attr.value, attr.name);
      if (resolved.pending) continue;
      updates[descriptor.name] = resolved.present ? resolved.value : null;
      rawValues.push({ name: attr.name, value: attr.value });
      changed = true;
    }

    // A removed attribute is a nil update for a declared prop. The mount path
    // never takes this branch because it only records attributes that exist.
    if (names) {
      names.forEach(function (name) {
        var descriptor = propDescriptorFor(component, name);
        if (!descriptor || seen[descriptor.name]) return;
        if (descriptor.required) {
          throw propError(descriptor, "is required but the attribute was removed", name);
        }
        if (attributeValueIsCurrent(element, name, null)) return;
        updates[descriptor.name] = null;
        rawValues.push({ name: name, value: null });
        changed = true;
      });
    }

    return { updates: updates, rawValues: rawValues, changed: changed };
  }

  function syncDeclaredProps(module, instance, element, names) {
    var component = element && element._mochiComponent;
    var collected = collectDeclaredPropUpdates(component, element, names);
    if (!collected || !collected.changed) return false;
    if (typeof module._mochi_set_props_json !== "function") {
      throw new Error("mochi-loader: runtime does not support declared props");
    }
    var json = JSON.stringify(collected.updates);
    var result = withUtf8(module, json, function (pointer, length) {
      return module._mochi_set_props_json(instance, pointer, length);
    });
    if (result !== 0) {
      throw new Error("mochi-loader: prop update failed: " + lastError(module));
    }
    collected.rawValues.forEach(function (entry) {
      rememberAttributeValue(element, entry.name, entry.value);
    });
    return true;
  }

  // Host attribute -> component prop ABI. `_mochi_set_ivar_string` returns 0 on
  // success and -1 on failure with the VM message read through lastError.
  // Removal arrives as a missing attribute and is written as the empty string,
  // the historical string default; it does not re-run `initialize`. An
  // unchanged value is skipped here, and the VM also marks no dirty ivar for an
  // equal value, so echoing the current attribute cannot create an update loop.
  function syncElementAttribute(module, instance, name, value, element) {
    if (!module || typeof module._mochi_set_ivar_string !== "function") return false;
    if (!name || name.indexOf("data-mochi-") === 0 || name.indexOf("on") === 0) return false;
    // Declared props travel through the typed batch path.
    if (propDescriptorFor(element && element._mochiComponent, name)) return false;
    var strVal = value === null || value === undefined ? "" : String(value);
    if (attributeValueIsCurrent(element, name, strVal)) return false;
    var result = withUtf8(module, name.replace(/-/g, "_"), function (nPtr, nLen) {
      return withUtf8(module, strVal, function (vPtr, vLen) {
        return module._mochi_set_ivar_string(instance, nPtr, nLen, vPtr, vLen);
      });
    });
    if (result !== 0) {
      throw new Error("mochi-loader: attribute setter failed for \"" + name + "\": " +
        lastError(module));
    }
    rememberAttributeValue(element, name, strVal);
    return true;
  }

  // Re-reads every current host attribute. Declared props go through one typed
  // batch; undeclared attributes keep the historical string-ivar path. Returns
  // true when any value changed; mount ignores the flag because the first
  // binding flush follows immediately.
  function syncAllElementAttributes(module, instance, element) {
    if (!element || !element.attributes) return false;
    var changed = syncDeclaredProps(module, instance, element, null);
    for (var i = 0; i < element.attributes.length; i++) {
      var attr = element.attributes[i];
      if (syncElementAttribute(module, instance, attr.name, attr.value, element)) changed = true;
    }
    return changed;
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

    var declared = resolveMountProps(component, element);
    if (declared && typeof module._mochi_mount_component_props !== "function") {
      throw new Error("mochi-loader: runtime does not support declared props");
    }

    var instance;

    withUtf8(module, component.class_name, function (pointer, length) {
      if (declared) {
        withUtf8(module, declared.json, function (jsonPointer, jsonLength) {
          instance = module._mochi_mount_component_props(
            pointer, length, jsonPointer, jsonLength);
        });
      } else {
        instance = module._mochi_mount_component(pointer, length);
      }
    });

    if (instance === 0 || instance === 0n) {
      throw new Error("mochi-loader: mount failed for " + component.class_name + ": " + lastError(module));
    }

    var mountedStarted = false;
    try {
      if (declared) {
        // The props were installed as part of the mount transaction. Recording
        // the raw values keeps the immediate resync from writing them again.
        declared.rawValues.forEach(function (entry) {
          rememberAttributeValue(element, entry.name, entry.value);
        });
      }
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

    if ((binding.kind === "html" || binding.kind === "text_html") && node.nodeType === 3) {
      var span = global.document.createElement("span");
      span.textContent = node.textContent;
      node.parentNode.replaceChild(span, node);
      node = span;
    }
    if (binding.kind === "text" || binding.kind === "text_html") {
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

  function eventModifiers(target, eventName) {
    var raw = target.getAttribute("data-mochi-modifiers-" + eventName);
    if (!raw) return [];
    return raw.split(",").filter(function (modifier) { return modifier.length > 0; });
  }

  // `document.activeElement` retargets to a shadow host. Walk into each open
  // shadow root so focus capture and restore keep the real focused element.
  function deepActiveElement(root) {
    var scope = root || global.document;
    var active = scope && scope.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) {
      active = active.shadowRoot.activeElement;
    }
    return active || null;
  }

  function focusNode(node) {
    if (!node || typeof node.focus !== "function") return false;
    try {
      node.focus({ preventScroll: true });
    } catch (error) {
      try {
        node.focus();
      } catch (fallbackError) {
        return false;
      }
    }
    var active = deepActiveElement();
    return active === node || node === global.document.body;
  }

  function nodeContainsFocus(host, node) {
    if (!node) return true;
    if (host.contains && host.contains(node)) return true;
    var root = host.shadowRoot;
    return !!(root && root.contains && root.contains(node));
  }

  function focusCandidate(node) {
    while (node) {
      if (node.nodeType === 1 && typeof node.focus === "function") return node;
      node = node.parentNode;
    }
    return null;
  }

  function rememberFocus(host, target) {
    var active = deepActiveElement();
    if (!active || active === host) return;

    // A trap can contain several focus targets. Moving between them must not
    // grow the restore stack; only focus that came from outside is remembered.
    var trap = focusTrapFor(target);
    if (trap && (trap === active || nodeContainsFocus(trap, active))) return;
    if (!trap && nodeContainsFocus(host, active)) return;

    if (active === global.document.body) {
      // Firefox does not focus a button on mouse click. Fall back to the
      // element whose handler opened the dialog.
      active = focusCandidate(state.lastEventTarget) || active;
    }
    var stack = focusStacks.get(host);
    if (!stack) {
      stack = [];
      focusStacks.set(host, stack);
    }
    stack.push(active);
  }

  function restoreRememberedFocus(host) {
    var stack = focusStacks.get(host);
    while (stack && stack.length > 0) {
      var target = stack.pop();
      if (target && target.isConnected !== false && focusNode(target)) return true;
    }
    return false;
  }

  function findNamedRef(host, name) {
    var root = host && host.shadowRoot;
    if (!root) return null;
    var escaped = global.CSS && typeof global.CSS.escape === "function"
      ? global.CSS.escape(name)
      : String(name).replace(/["\\]/g, "\\$&");
    return root.querySelector('[data-mochi-ref="' + escaped + '"]') ||
      root.querySelector('[ref="' + escaped + '"]');
  }

  var FOCUSABLE_SELECTOR = [
    "a[href]",
    "area[href]",
    "button",
    "input",
    "select",
    "textarea",
    "iframe",
    "object",
    "embed",
    "[contenteditable]",
    "[tabindex]"
  ].join(",");

  function focusableNode(node) {
    if (!node || node.nodeType !== 1) return false;
    if (node.disabled || node.hidden || node.hasAttribute("inert")) return false;
    if (node.getAttribute("aria-hidden") === "true") return false;
    if (node.getAttribute("tabindex") === "-1") return false;
    return node.matches(FOCUSABLE_SELECTOR);
  }

  function collectFocusables(container) {
    var result = [];
    function visitChildren(parent) {
      for (var child = parent.firstElementChild; child; child = child.nextElementSibling) {
        visit(child);
      }
    }
    function visit(node) {
      if (!node || node.nodeType !== 1) return;
      if (focusableNode(node)) result.push(node);
      if (node.shadowRoot) visitChildren(node.shadowRoot);
      else visitChildren(node);
    }
    if (container.shadowRoot) visitChildren(container.shadowRoot);
    else visitChildren(container);
    return result;
  }

  function focusTrapFor(node) {
    while (node) {
      if (node.nodeType === 1 &&
          (node.hasAttribute("data-mochi-focus-trap") || node.hasAttribute("focus-trap"))) {
        return node;
      }
      if (node.parentNode) {
        node = node.parentNode;
      } else if (node.host) {
        node = node.host;
      } else {
        break;
      }
    }
    return null;
  }

  function handleFocusTrapKeydown(event) {
    if (!event || event.key !== "Tab" || event.defaultPrevented) return;
    var active = deepActiveElement();
    var trap = focusTrapFor(active);
    if (!trap) return;

    var items = collectFocusables(trap);
    if (items.length === 0) {
      event.preventDefault();
      focusNode(trap);
      return;
    }

    var index = items.indexOf(active);
    var edge = event.shiftKey
      ? (index === -1 || index === 0)
      : (index === -1 || index === items.length - 1);
    if (!edge) return;

    event.preventDefault();
    focusNode(event.shiftKey ? items[items.length - 1] : items[0]);
  }

  function installFocusTrap() {
    if (!global.document || typeof global.document.addEventListener !== "function") return;
    if (state.focusTrapDocument === global.document) return;
    global.document.addEventListener("keydown", handleFocusTrapKeydown, true);
    state.focusTrapDocument = global.document;
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

  // Ruby gets labels and attributes, never a live DOM node. The same shape is
  // used for target, the bound current target, and each composed-path entry.
  function eventNodeInfo(node) {
    if (!node || node.nodeType !== 1) return null;
    var tag = String(node.tagName || "").toLowerCase();
    return {
      tag: tag,
      id: node.id || "",
      ref: node.getAttribute("data-mochi-ref") || node.getAttribute("ref") || "",
      component: node.localName && node.localName.indexOf("-") !== -1 ? node.localName : ""
    };
  }

  function composedPathInfo(event, source) {
    var path = [];
    if (event && typeof event.composedPath === "function") {
      path = event.composedPath();
    }
    if ((!path || path.length === 0) && source) {
      var node = source;
      while (node && path.length < 32) {
        path.push(node);
        node = node.parentNode || (node.host || null);
      }
    }
    var result = [];
    for (var i = 0; i < path.length && result.length < 32; i++) {
      var info = eventNodeInfo(path[i]);
      if (info) result.push(info);
    }
    return result;
  }

  function eventPayload(target, event) {
    if (event && event.__mochiChildEvent) {
      return event.detail === undefined || event.detail === null ? {} : event.detail;
    }
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

    var targetInfo = eventNodeInfo(source);
    var currentTargetInfo = eventNodeInfo(target);
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
      target_ref: targetInfo ? targetInfo.ref : "",
      target_tag: targetInfo ? targetInfo.tag : "",
      current_target_id: currentTargetInfo ? currentTargetInfo.id : "",
      current_target_ref: currentTargetInfo ? currentTargetInfo.ref : "",
      current_target_tag: currentTargetInfo ? currentTargetInfo.tag : "",
      target: targetInfo,
      current_target: currentTargetInfo,
      composed_path: composedPathInfo(event, source),
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
    if (descriptor.literal_type === "number") {
      if (!integerTextInInt64(value)) {
        throw new Error("mochi-loader: event literal " + value + " is outside the signed 64-bit range");
      }
      return integerTransportValue(value);
    }
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
        var value = bindingValues[binding.id];
        return nilBinding(value) ? null : value;
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
    if (binding.trusted_markup) {
      state.trusted = state.trusted || {};
      state.trusted[binding.id] = true;
    }
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

  function substitute(state, values, escapeMarkup) {
    var template = String(state.template || "");
    var result = "";

    function literal(text) {
      return escapeMarkup ? escapeHtmlText(text) : text;
    }

    function valueFor(id, fallback) {
      if (id === undefined || !Object.prototype.hasOwnProperty.call(values, id)) {
        return literal(fallback);
      }
      var value = displayBindingValue(values[id]);
      if (!escapeMarkup || (state.trusted && state.trusted[id])) return value;
      return escapeHtmlText(value);
    }

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
        result += literal(template.slice(cursor, entry.start));
        result += valueFor(entry.id, template.slice(entry.start, entry.end));
        cursor = entry.end;
      }
      result += literal(template.slice(cursor));
      return unescapeBraces(result);
    }

    var index = 0;
    var fallbackCursor = 0;
    template.replace(/\{([^}]+)\}/g, function (match, inner, offset) {
      result += literal(template.slice(fallbackCursor, offset));
      var id = state.ids[index++];
      result += valueFor(id, match);
      fallbackCursor = offset + match.length;
      return match;
    });
    result += literal(template.slice(fallbackCursor));
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
        attrKind: attributeKind(binding),
        ids: [],
        entries: [],
        values: {}
      };
    }
    var state = target.__mochiAttrs[name];
    if (attributeKind(binding) === "boolean") state.attrKind = "boolean";
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
    if (binding.kind === "text_html") {
      target.innerHTML = substitute(state, state.values, true);
    } else {
      target.textContent = substitute(state, state.values, false);
    }
  }

  function applyHtmlPatch(target, binding, value) {
    if (!binding.trusted_markup) {
      throw new Error("mochi-loader: html binding " + binding.id + " is missing trusted_markup");
    }
    if (target.__mochiHtmlValue === value) return;
    target.__mochiHtmlValue = value;
    target.innerHTML = displayBindingValue(value);
  }

  var BOOLEAN_ATTRIBUTES = {
    allowfullscreen: true,
    async: true,
    autofocus: true,
    autoplay: true,
    checked: true,
    controls: true,
    default: true,
    defer: true,
    disabled: true,
    formnovalidate: true,
    hidden: true,
    inert: true,
    ismap: true,
    itemscope: true,
    loop: true,
    multiple: true,
    muted: true,
    nomodule: true,
    novalidate: true,
    open: true,
    playsinline: true,
    readonly: true,
    required: true,
    reversed: true,
    selected: true
  };
  var TEXTUAL_ATTRIBUTE_PREFIXES = ["aria-", "data-"];

  // The compiler records the distinction in the manifest. The name fallback
  // keeps hand-written manifests and older bundles working.
  function attributeKindForName(name) {
    var normalized = String(name || "").toLowerCase();
    for (var i = 0; i < TEXTUAL_ATTRIBUTE_PREFIXES.length; i++) {
      if (normalized.indexOf(TEXTUAL_ATTRIBUTE_PREFIXES[i]) === 0) return "text";
    }
    return BOOLEAN_ATTRIBUTES[normalized] ? "boolean" : "text";
  }

  function attributeKind(binding) {
    if (binding && (binding.attr_kind === "boolean" || binding.attr_kind === "text")) {
      return binding.attr_kind;
    }
    return attributeKindForName(binding && binding.attr_name);
  }

  function singlePlaceholder(state, binding) {
    if (state.entries.length === 1) {
      if (state.entries[0].id !== binding.id) return false;
      var entry = entryRange(state, state.entries[0]);
      return state.template.slice(0, entry.start).trim() === "" &&
        state.template.slice(entry.end).trim() === "";
    }
    return state.entries.length === 0 && state.ids.length === 1 &&
      /^\s*\{[^}]+\}\s*$/.test(state.template);
  }

  function booleanAttributePresent(value) {
    if (nilBinding(value) || value === null || value === undefined || value === false) {
      return false;
    }
    var text = String(value).trim().toLowerCase();
    return text !== "" && text !== "false";
  }

  function applyAttrPatch(target, binding, value) {
    var state = attrBindingState(target, binding);
    if (state.values[binding.id] === value) return;
    state.values[binding.id] = value;
    var nextValue = substitute(state, state.values);
    var alone = singlePlaceholder(state, binding);
    var remove;
    if (state.attrKind === "boolean") {
      remove = !booleanAttributePresent(alone ? value : nextValue);
    } else {
      remove = alone && (nilBinding(value) || value === null || value === undefined);
    }
    if (remove) {
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
      next = !nilBinding(value) && (value === "true" || value === "checked" || value === "1");
    } else {
      next = displayBindingValue(value);
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
    if (nilBinding(value) || value === "false" || value === "-1" || value === "" ||
        value === null || value === undefined) return -1;

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
    if (binding.kind === "text" || binding.kind === "text_html") {
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

  var ROW_SENTINEL_PATTERN = /\uE002(\d+)\uE003/g;
  var ROW_TEXT_MARKER = "mochi-row-text-";
  var ROW_HTML_START_MARKER = "mochi-row-html-start-";
  var ROW_HTML_END_MARKER = "mochi-row-html-end-";
  var ROW_START_MARKER = "mochi-row-start";
  var ROW_END_MARKER = "mochi-row-end";
  var LIST_START_MARKER = "mochi-list-start";

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
    if (isMochiNumber(value)) return mochiNumberText(value);
    if (typeof value === "object") {
      try {
        return JSON.stringify(value);
      } catch (error) {
        return "";
      }
    }
    return String(value);
  }

  function rowTemplateMarkup(descriptor) {
    var bySlot = {};
    (descriptor.bindings || []).forEach(function (binding) {
      bySlot[binding.slot] = binding;
    });
    return String(descriptor.template || "").replace(ROW_SENTINEL_PATTERN, function (match, rawSlot) {
      var binding = bySlot[Number(rawSlot)];
      if (!binding) return match;
      if (binding.kind === "html") {
        if (!binding.trusted_markup) {
          throw new Error("mochi-loader: row html binding " + binding.slot + " is missing trusted_markup");
        }
        return "<!--" + ROW_HTML_START_MARKER + binding.slot + "--><!--" +
          ROW_HTML_END_MARKER + binding.slot + "-->";
      }
      if (binding.kind === "attr") return match;
      return "<!--" + ROW_TEXT_MARKER + binding.slot + "-->";
    });
  }

  function findCommentNode(root, value) {
    var stack = [root];
    while (stack.length > 0) {
      var node = stack.pop();
      var children = node.childNodes || [];
      for (var i = 0; i < children.length; i++) {
        var child = children[i];
        if (child.nodeType === 8 && child.nodeValue === value) return child;
        if (child.childNodes && child.childNodes.length > 0) stack.push(child);
      }
    }
    return null;
  }

  function findEachAnchor(root, blockId) {
    return findCommentNode(root, "mochi-each-" + blockId);
  }

  function unescapeRowText(root) {
    var stack = [root];
    while (stack.length > 0) {
      var node = stack.pop();
      if (node.nodeType === 3) node.nodeValue = unescapeBraces(node.nodeValue);
      var children = node.childNodes || [];
      for (var i = 0; i < children.length; i++) {
        if (children[i].childNodes && children[i].childNodes.length > 0) stack.push(children[i]);
      }
    }
  }

  function collectRowSlotHosts(fragment, descriptor) {
    var textHosts = [];
    var htmlHosts = [];
    (descriptor.bindings || []).forEach(function (binding) {
      if (binding.kind === "html") {
        var start = findCommentNode(fragment, ROW_HTML_START_MARKER + binding.slot);
        var end = findCommentNode(fragment, ROW_HTML_END_MARKER + binding.slot);
        if (!start || !end) {
          throw new Error("mochi-loader: missing row html slot " + binding.slot +
            " for binding descriptor " + descriptor.id);
        }
        htmlHosts.push({ slot: binding.slot, start: start, end: end, value: undefined });
      } else if (binding.kind === "text") {
        var marker = findCommentNode(fragment, ROW_TEXT_MARKER + binding.slot);
        if (!marker) {
          throw new Error("mochi-loader: missing row text slot " + binding.slot +
            " for binding descriptor " + descriptor.id);
        }
        var node = global.document.createTextNode("");
        marker.parentNode.replaceChild(node, marker);
        textHosts.push({ slot: binding.slot, node: node, value: undefined });
      }
    });
    return { textHosts: textHosts, htmlHosts: htmlHosts };
  }

  function rowAttributeKind(descriptor, name) {
    var kind = null;
    (descriptor.bindings || []).forEach(function (binding) {
      if (binding.kind !== "attr" || binding.attr_name !== name) return;
      if (binding.attr_kind === "boolean" || binding.attr_kind === "text") {
        kind = binding.attr_kind;
      }
    });
    return kind || attributeKindForName(name);
  }

  function collectRowAttrHosts(fragment, descriptor) {
    var elements = [];
    if (fragment.nodeType === 1) elements.push(fragment);
    Array.prototype.push.apply(elements, Array.from(fragment.querySelectorAll("*")));
    var hosts = [];
    elements.forEach(function (element) {
      Array.from(element.attributes || []).forEach(function (attribute) {
        var value = unescapeBraces(attribute.value);
        if (value.indexOf("\uE002") === -1) {
          if (value !== attribute.value) element.setAttribute(attribute.name, value);
          return;
        }
        hosts.push({
          element: element,
          name: attribute.name,
          template: value,
          attrKind: rowAttributeKind(descriptor, attribute.name),
          value: undefined
        });
      });
    });
    return hosts;
  }

  function buildRowEntry(descriptor, row, index, parentContext) {
    var fragment = fragmentFor(rowTemplateMarkup(descriptor));
    unescapeRowText(fragment);
    var slotHosts = collectRowSlotHosts(fragment, descriptor);
    var attrHosts = collectRowAttrHosts(fragment, descriptor);
    var context = {
      blockId: descriptor.id,
      item: row[0],
      index: index,
      parent: parentContext || null
    };

    // Tag only this row's own top-level elements. Nested row nodes are inserted
    // later, so their child context cannot be overwritten by the parent.
    Array.from(fragment.childNodes).forEach(function (node) {
      if (node.nodeType === 1) node.__mochiEachContext = context;
    });

    var childAnchors = new Map();
    (descriptor.children || []).forEach(function (child) {
      var anchor = findEachAnchor(fragment, child.id);
      if (!anchor) {
        throw new Error("mochi-loader: missing nested list anchor " + child.id +
          " for binding descriptor " + descriptor.id);
      }
      childAnchors.set(child.id, anchor);
    });

    var start = global.document.createComment(ROW_START_MARKER);
    var end = global.document.createComment(ROW_END_MARKER);
    fragment.insertBefore(start, fragment.firstChild);
    fragment.appendChild(end);

    return {
      descriptor: descriptor,
      start: start,
      end: end,
      context: context,
      textHosts: slotHosts.textHosts,
      htmlHosts: slotHosts.htmlHosts,
      attrHosts: attrHosts,
      childAnchors: childAnchors
    };
  }

  function assignRowText(host, value) {
    var next = displayRowValue(value);
    if (host.value === next) return;
    host.value = next;
    host.node.nodeValue = next;
  }

  function assignRowHtml(host, value) {
    var next = displayRowValue(value);
    if (host.value === next) return;
    host.value = next;
    var parent = host.start.parentNode;
    if (!parent) throw new Error("mochi-loader: detached row html slot " + host.slot);
    var node = host.start.nextSibling;
    while (node && node !== host.end) {
      var after = node.nextSibling;
      parent.removeChild(node);
      node = after;
    }
    parent.insertBefore(fragmentFor(next), host.end);
  }

  function assignRowAttribute(host, values) {
    var slots = [];
    var next = host.template.replace(ROW_SENTINEL_PATTERN, function (match, rawSlot) {
      slots.push(Number(rawSlot));
      return displayRowValue(values[Number(rawSlot)]);
    });
    var alone = slots.length === 1 &&
      host.template.replace(ROW_SENTINEL_PATTERN, "").trim() === "";
    var raw = alone ? values[slots[0]] : undefined;
    var remove;
    if (host.attrKind === "boolean") {
      remove = !booleanAttributePresent(alone ? raw : next);
    } else {
      remove = alone && (raw === null || raw === undefined);
    }

    if (host.value === next && host.removed === remove) return;
    host.value = next;
    host.removed = remove;
    if (remove) {
      host.element.removeAttribute(host.name);
    } else {
      host.element.setAttribute(host.name, next);
    }
  }

  function assignRowSlots(entry, row) {
    var values = Array.isArray(row[1]) ? row[1] : [];
    entry.textHosts.forEach(function (host) { assignRowText(host, values[host.slot]); });
    entry.htmlHosts.forEach(function (host) { assignRowHtml(host, values[host.slot]); });
    entry.attrHosts.forEach(function (host) { assignRowAttribute(host, values); });
  }

  function rowKeyToken(value) {
    if (typeof value === "string") return "s:" + value;
    if (typeof value === "number") return "n:" + String(value);
    if (isMochiNumber(value)) return "mn:" + mochiNumberKind(value) + ":" + mochiNumberText(value);
    if (typeof value === "boolean") return "b:" + String(value);
    if (value && typeof value === "object") {
      try {
        return "o:" + JSON.stringify(value);
      } catch (error) {
        return "o:" + String(value);
      }
    }
    return "u:" + String(value);
  }

  function rowKeyLabel(value) {
    if (typeof value === "string") return value;
    if (isMochiNumber(value)) return mochiNumberText(value);
    if (value && typeof value === "object") {
      try {
        return JSON.stringify(value);
      } catch (error) {
        return String(value);
      }
    }
    return String(value);
  }

  function rowIdentity(row, index, descriptor) {
    if (descriptor && descriptor.keyed) {
      var key = row[3];
      if (key === undefined || key === null) {
        throw new Error("mochi-loader: keyed list row for binding descriptor " +
          descriptor.id + " at index " + index + " is missing a key");
      }
      return { key: "k:" + rowKeyToken(key), label: rowKeyLabel(key) };
    }

    var item = row[0];
    if (item && typeof item === "object") {
      if (item.key !== undefined && item.key !== null) {
        return { key: "k:" + rowKeyToken(item.key), label: rowKeyLabel(item.key) };
      }
      if (item.id !== undefined && item.id !== null) {
        return { key: "k:" + rowKeyToken(item.id), label: rowKeyLabel(item.id) };
      }
    }
    return { key: "i:" + index, label: String(index) };
  }

  function rowSourceLocation(descriptor) {
    var source = descriptor && descriptor.source;
    if (!source || !source.file) return "";
    return " in " + source.file + ":" + source.line + ":" + source.column;
  }

  function prepareEachRows(descriptor, rows) {
    var seen = new Map();
    return rows.map(function (row, index) {
      if (!Array.isArray(row) || row.length < 2) {
        throw new Error("mochi-loader: invalid list row for binding descriptor " +
          descriptor.id + " at index " + index);
      }
      var identity = rowIdentity(row, index, descriptor);
      if (seen.has(identity.key)) {
        throw new Error("mochi-loader: duplicate list key " +
          JSON.stringify(identity.label) + " at rows " + seen.get(identity.key) +
          " and " + index + rowSourceLocation(descriptor));
      }
      seen.set(identity.key, index);
      return { row: row, index: index, key: identity.key };
    });
  }

  function rowRange(entry) {
    var nodes = [];
    var node = entry.start;
    while (node) {
      nodes.push(node);
      if (node === entry.end) return nodes;
      node = node.nextSibling;
    }
    throw new Error("mochi-loader: list row range is detached");
  }

  function removeRowEntry(entry) {
    removeNodes(rowRange(entry));
  }

  function insertRowBefore(entry, anchor) {
    var parent = anchor.parentNode;
    if (!parent) return;
    rowRange(entry).forEach(function (node) {
      parent.insertBefore(node, anchor);
    });
  }

  function moveRowAfter(entry, reference) {
    var parent = reference.parentNode;
    if (!parent) return;
    var anchor = reference.nextSibling;
    rowRange(entry).forEach(function (node) {
      parent.insertBefore(node, anchor);
    });
  }

  function updateRowEntry(entry, row, index) {
    entry.context.item = row[0];
    entry.context.index = index;
    assignRowSlots(entry, row);
    reconcileRowChildren(entry, row);
  }

  function reconcileRowChildren(entry, row) {
    var children = row[2];
    if (children === undefined || children === null) children = [];
    if (!Array.isArray(children)) {
      throw new Error("mochi-loader: nested list rows must be an array for binding descriptor " +
        entry.descriptor.id);
    }
    (entry.descriptor.children || []).forEach(function (child, childIndex) {
      var childRows = children[childIndex] || [];
      if (!Array.isArray(childRows)) {
        throw new Error("mochi-loader: nested list rows must be an array for binding descriptor " +
          child.id);
      }
      var anchor = entry.childAnchors.get(child.id);
      if (!anchor) {
        throw new Error("mochi-loader: missing nested list anchor " + child.id +
          " for binding descriptor " + entry.descriptor.id);
      }
      reconcileEach(anchor, child, childRows, entry.context);
    });
  }

  function reconcileEach(anchor, descriptor, rows, parentContext) {
    if (!Array.isArray(rows)) {
      throw new Error("mochi-loader: each patch must be an array for binding " + descriptor.id);
    }
    var parent = anchor.parentNode;
    if (!parent) return;

    // Validate every key before touching the DOM so duplicate keys cannot
    // leave newly built rows or child instances behind.
    var planned = prepareEachRows(descriptor, rows);

    var state = anchor.__mochiEach;
    if (!state) state = anchor.__mochiEach = { items: new Map(), start: null };
    if (!state.start || state.start.parentNode !== parent) {
      var listStart = global.document.createComment(LIST_START_MARKER);
      parent.insertBefore(listStart, anchor);
      state.start = listStart;
    }

    var previous = state.items;
    var next = new Map();
    var ordered = [];
    planned.forEach(function (item) {
      var entry = previous.get(item.key);
      item.isNew = !entry;
      if (!entry) entry = buildRowEntry(descriptor, item.row, item.index, parentContext);
      item.entry = entry;
      next.set(item.key, entry);
      ordered.push(entry);
    });

    // Finish every row update before attaching new ranges. A failure while
    // building a later row cannot strand an earlier new row in the DOM.
    planned.forEach(function (item) {
      updateRowEntry(item.entry, item.row, item.index);
    });
    planned.forEach(function (item) {
      if (item.isNew) insertRowBefore(item.entry, anchor);
    });

    previous.forEach(function (entry, key) {
      if (!next.has(key)) removeRowEntry(entry);
    });

    var reference = state.start;
    ordered.forEach(function (entry) {
      if (entry.start !== reference.nextSibling) moveRowAfter(entry, reference);
      reference = entry.end;
    });

    state.items = next;
  }

  function applyEachPatch(element, target, binding, value) {
    var descriptor = eachRowDescriptor(binding);
    var rows;
    if (nilBinding(value) || !value) {
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
    reconcileEach(target, descriptor, rows, null);
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

  function styleResourceText(id, tag) {
    var resources = state.manifest && state.manifest.resources;
    var resource = resources && resources[id];
    if (!resource || resource.kind !== "style" || typeof resource.text !== "string") {
      throw new Error(
        (tag || "component") + " references missing style resource " + id
      );
    }
    return resource.text;
  }

  function canAdoptStyleSheets(root) {
    if (typeof global.CSSStyleSheet !== "function") return false;
    if (typeof global.CSSStyleSheet.prototype.replaceSync !== "function") return false;
    return "adoptedStyleSheets" in root;
  }

  function sharedStyleSheet(id, tag) {
    if (state.styleSheetCache.has(id)) return state.styleSheetCache.get(id);
    var sheet = new global.CSSStyleSheet();
    sheet.replaceSync(styleResourceText(id, tag));
    state.styleSheetCache.set(id, sheet);
    return sheet;
  }

  function localStyleSheet(component) {
    var cached = state.localStyleSheetCache.get(component);
    if (cached) return cached;
    var sheet = new global.CSSStyleSheet();
    sheet.replaceSync(component.css || "");
    state.localStyleSheetCache.set(component, sheet);
    return sheet;
  }

  function appendStyleElement(root, text, resourceId) {
    var style = global.document.createElement("style");
    if (resourceId) style.setAttribute("data-mochi-style-resource", resourceId);
    style.textContent = text;
    root.appendChild(style);
  }

  function installComponentStyles(root, component) {
    var ids = component.style_resources || [];
    var localCss = component.css || "";
    var tag = component.tag_name || component.class_name || "";
    if (canAdoptStyleSheets(root)) {
      var sheets = ids.map(function (id) {
        return sharedStyleSheet(id, tag);
      });
      if (localCss) sheets.push(localStyleSheet(component));
      root.adoptedStyleSheets = sheets;
      return;
    }

    // Fallback for browsers without constructable stylesheets. Shared text is
    // copied from the manifest, never fetched a second time. Local CSS comes
    // last so its overrides win in both paths.
    ids.forEach(function (id) {
      appendStyleElement(root, styleResourceText(id, tag), id);
    });
    if (localCss) appendStyleElement(root, localCss, null);
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
        this._mochiAttributeValues = null;
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
        this.mochiError = undefined;
        this._mochiDisconnected = false;
        this._mochiDisposalScheduled = false;
        this._mochiUnmounted = false;
        this._mochiModule = null;
        this._mochiInstance = null;
        this._mochiAttributeValues = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.bindingData = {};
        focusStacks.delete(this);
        allBindings.forEach(function (binding) {
          this.bindingData[binding.id] = binding;
        }, this);
        this.refs = this.bindingTargets;
        this._mochiMountToken = ++state.nextMountToken;
        var mountToken = this._mochiMountToken;

        try {
          installComponentStyles(root, component);
        } catch (error) {
          this._mochiMountState = "failed";
          reportError(this, "style", "", error);
          return;
        }

        var fragment = template.content.cloneNode(true);
        try {
          this._resolveBindings(fragment);
          root.appendChild(fragment);
        } catch (error) {
          this._mochiMountState = "failed";
          reportError(this, "binding", "", error);
          return;
        }
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
            element.mochiError = undefined;

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
              throw reportError(
                element, "mount", methodFromError(error, "initialize"),
                error, element._mochiModule
              );
            }
            console.error("[mochi] " + tag + " stale mount failed", error);
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
        // A value set while the element was detached, or between instance
        // creation and observer installation, must not be lost.
        syncAllElementAttributes(module, instance, element);
        this._mochiAttrObserver = new global.MutationObserver(function (mutations) {
          if (element._mochiDisconnected || element._mochiUnmounted) return;
          // One callback may carry several records for the same attribute.
          // Coalesce them to the current value and write each prop once.
          var names = Object.create(null);
          for (var i = 0; i < mutations.length; i++) {
            var recordName = mutations[i].attributeName;
            if (recordName) names[recordName] = true;
          }
          var attrNames = Object.keys(names);
          var changed = false;
          try {
            if (syncDeclaredProps(module, instance, element, attrNames)) changed = true;
          } catch (error) {
            reportError(element, "attribute",
              error.mochiContext && error.mochiContext.property || "",
              error, module);
          }
          attrNames.forEach(function (attrName) {
            try {
              if (syncElementAttribute(module, instance, attrName,
                element.getAttribute(attrName), element)) {
                changed = true;
              }
            } catch (error) {
              reportError(element, "attribute", attrName, error, module, {
                attribute: attrName,
                property: attrName.replace(/-/g, "_")
              });
            }
          });
          if (!changed) return;
          try {
            applyPatches(element, module);
            drainEmits(module);
            drainFetches(module);
          } catch (error) {
            reportError(element, "attribute", "", error, module);
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
        this._mochiAttributeValues = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        focusStacks.delete(this);
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
          reportError(this, "unmount", "unmounted", error, module);
        }

        // Host drains run even when the hook failed. Consuming the fetch outbox
        // while the instance is still marked unmounted prevents a later mount
        // from inheriting the old handle's requests.
        try {
          drainEmits(module);
        } catch (error) {
          reportError(this, "unmount", "emit", error, module);
        }
        try {
          drainFetches(module);
        } catch (error) {
          reportError(this, "unmount", "fetch", error, module);
        }

        var disposeError = disposeVmInstance(module, instance);
        if (disposeError) {
          reportError(this, "unmount", "dispose", disposeError, module);
        }

        this._mochiModule = null;
        this._mochiInstance = null;
        this._mochiAttributeValues = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        focusStacks.delete(this);
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
        if (!method) return;

        // Native modifiers must run during this listener, before browser
        // dispatch ends and before any Ruby work is queued.
        var modifiers = eventModifiers(target, event.type);
        if (modifiers.indexOf("self") !== -1 && event.target !== target) return;
        if (modifiers.indexOf("prevent") !== -1 && typeof event.preventDefault === "function") {
          event.preventDefault();
        }
        if (modifiers.indexOf("stop") !== -1 && typeof event.stopPropagation === "function") {
          event.stopPropagation();
        }
        state.lastEventTarget = event.target;
        if (!this._mochiReady) return;

        var payload = eventPayload(target, event);
        var eachContexts = findEachContexts(target, this.shadowRoot);
        var nearestEachContext = eachContexts.length > 0 ? eachContexts[eachContexts.length - 1] : null;
        if (nearestEachContext && !(event && event.__mochiChildEvent)) {
          payload.item = nearestEachContext.item;
          payload.index = nearestEachContext.index;
        }
        var descriptors;

        try {
          descriptors = eventArguments(target, event.type);
        } catch (error) {
          reportError(element, "event", method, error);
          return;
        }

        var mountToken = this._mochiMountToken;
        this._mochiReady.then(function (mounted) {
          if (element._mochiDisconnected || element._mochiUnmounted ||
              mounted.mountToken !== element._mochiMountToken ||
              mountToken !== element._mochiMountToken) {
            return;
          }
          // A child event is dispatched on its emitting element. If that row
          // or child is removed before the queued handler runs, never deliver
          // it to a replacement element or parent state.
          if (!target || target._mochiUnmounted || !target.isConnected) return;
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
          reportError(element, "event", method, error, element._mochiModule);
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
          reportError(this, "action", action, error, module);
        }
      }
    };

    state.tags.add(tag);
    global.customElements.define(tag, Element);
  }

  function validateManifest(manifest, manifestUrl) {
    if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
      throw new Error("mochi-loader: manifest " + manifestUrl + " must be a versioned object");
    }
    if (manifest.schema_version !== MANIFEST_SCHEMA_VERSION) {
      throw new Error("mochi-loader: unsupported manifest schema " +
        JSON.stringify(manifest.schema_version) + " in " + manifestUrl +
        "; this loader supports schema " + MANIFEST_SCHEMA_VERSION);
    }
    if (!Array.isArray(manifest.components)) {
      throw new Error("mochi-loader: manifest " + manifestUrl + " has no components array");
    }
    if (!manifest.packages || typeof manifest.packages !== "object" || Array.isArray(manifest.packages)) {
      throw new Error("mochi-loader: manifest " + manifestUrl + " has no package descriptors");
    }
    return manifest;
  }

  async function boot(url, options) {
    installFocusTrap();
    options = options || {};
    if (options.moduleFactory) loader.moduleFactory = options.moduleFactory;
    if (options.hostModuleFactory) loader.hostModuleFactory = options.hostModuleFactory;

    var manifestUrl = absoluteUrl(url || DEFAULT_MANIFEST, global.document.baseURI);
    if (state.manifestUrl === manifestUrl && state.manifest) return state.manifest;

    var response = await global.fetch(manifestUrl);
    if (!response.ok) throw new Error("mochi-loader: failed to fetch " + manifestUrl);

    var manifest = validateManifest(await response.json(), manifestUrl);

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
    hostModuleFactory: null,
    applyPatches: applyPatches,
    debugStats: debugStats,
    onError: null,
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
          reportError(null, "boot", "", error);
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
