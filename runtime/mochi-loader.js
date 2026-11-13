// mochi-loader.js - static Custom Element + Shadow DOM loader for mochi-gvm.
(function (global) {
  "use strict";

  var RITE_HEADER = new Uint8Array([0x52, 0x49, 0x54, 0x45, 0x30, 0x34, 0x30, 0x30, 0x00, 0x00]);
  var COMPONENT_DIR = "components/";
  var DEFAULT_MANIFEST = "mochi-manifest.json";
  var MANIFEST_SCHEMA_VERSION = 3;
  var CAPABILITY_LIMIT_KEYS = {
    formatting: { cache_entries: "host_format_cache_entries" },
    pointer: {},
    drag: { payload_bytes: "host_drag_payload_bytes" },
    network: {
      pending_requests: "host_network_pending_requests",
      response_bytes: "host_network_response_bytes",
      response_buffer_bytes: "host_network_buffer_bytes",
      envelope_bytes: "host_fetch_envelope_bytes"
    }
  };
  var GLOBAL_EVENT_QUEUE_CAPACITIES = [
    "host_event_queue_entries",
    "host_event_queue_bytes"
  ];

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
    descriptorPromises: new Map(),
    styleTextPromises: new Map(),
    styleTextCache: new Map(),
    componentRuntimeCache: new Map(),
    hostModulePromises: new Map(),
    hostAdapters: new Map(),
    hostAdapterRegistrations: new Map(),
    loadingHostAdapterUrl: null,
    pendingHostRequests: new Map(),
    internCache: new Map(),
    tags: new Set(),
    elements: new Map(),
    pendingFetches: [],
    activeFetches: new Map(),
    latestFetches: new Map(),
    timers: new Map(),
    unmountedInstances: new Set(),
    routeSubscribers: new Set(),
    storageSubscribers: new Map(),
    globalEventSubscribers: new Map(),
    globalEventQueue: [],
    globalEventQueueBytes: 0,
    globalEventQueueDraining: false,
    activeGlobalEventDelivery: null,
    activeActionContext: null,
    activePointerDispatch: null,
    activeDragDispatch: null,
    pointerMoves: new Map(),
    reportingGlobalEventOverflow: false,
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

  function assertCapacityProfile(module, manifest) {
    var expected = manifest.capacity_profile && manifest.capacity_profile.fingerprint;
    var actual = "<missing>";
    var actualProfile = null;
    if (module && typeof module._mochi_capacity_profile === "function" &&
        typeof module.UTF8ToString === "function") {
      try {
        actualProfile = JSON.parse(module.UTF8ToString(module._mochi_capacity_profile()));
        actual = actualProfile && actualProfile.fingerprint || "<invalid>";
      } catch (_) {
        actual = "<invalid>";
      }
    }
    var sameCapacities = actualProfile && manifest.capacity_profile &&
      actualProfile.schema_version === manifest.capacity_profile.schema_version &&
      actualProfile.memory_bytes === manifest.capacity_profile.memory_bytes &&
      JSON.stringify(actualProfile.capacities) === JSON.stringify(manifest.capacity_profile.capacities);
    if (typeof expected !== "string" || actual !== expected || !sameCapacities) {
      throw new Error("mochi-loader: runtime capacity fingerprint mismatch (expected " +
        JSON.stringify(expected || "<missing>") + ", actual " + JSON.stringify(actual) + ")");
    }
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
    var profile = state.manifest && state.manifest.capacity_profile;
    var capacityProfile = /(?:exhausted|exceeded)/i.test(detail) && profile
      ? profile.fingerprint
      : "";
    if (capacityProfile) detail += " (capacity profile " + capacityProfile + ")";
    return {
      phase: phase,
      tagName: component && component.tag_name || "",
      className: component && component.class_name || "",
      method: method || "",
      source: location,
      capacityProfile: capacityProfile,
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

  function decodeRoutePart(value) {
    try {
      return decodeURIComponent(value);
    } catch (error) {
      return value;
    }
  }

  function parseRouteQuery(search) {
    var query = {};
    if (!search) return query;
    search.split("&").forEach(function (pair) {
      if (!pair) return;
      var at = pair.indexOf("=");
      var rawKey = at < 0 ? pair : pair.slice(0, at);
      var rawValue = at < 0 ? "" : pair.slice(at + 1);
      var key = decodeRoutePart(rawKey.replace(/\+/g, " "));
      if (!key) return;
      query[key] = decodeRoutePart(rawValue.replace(/\+/g, " "));
    });
    return query;
  }

  function routeSegments(path) {
    var segments = [];
    String(path || "").split("/").forEach(function (part) {
      if (part) segments.push(decodeRoutePart(part));
    });
    return segments;
  }

  // A hash route owns the URL when present. Otherwise the router owns the
  // pathname and its query string. This keeps one navigation model per page
  // and avoids interpreting a pathname and a hash as competing routes.
  function currentRouteInfo() {
    if (!global.location) {
      return { path: "/", segments: [], query: {}, search: "", hash: false, href: "" };
    }
    var hash = global.location.hash || "";
    var hashRoute = hash.length > 1;
    var target = hashRoute ? hash.slice(1) : (global.location.pathname || "/");
    var search = "";
    var queryAt = target.indexOf("?");
    if (queryAt >= 0) {
      search = target.slice(queryAt + 1);
      target = target.slice(0, queryAt);
    } else if (!hashRoute && global.location.search && global.location.search.length > 1) {
      search = global.location.search.slice(1);
    }
    if (target.charAt(0) !== "/") target = "/" + target;
    // Opening the static entry file is the root route, not an unknown screen.
    if (!hashRoute && target === "/index.html") target = "/";
    var segments = routeSegments(target);
    return {
      path: "/" + segments.join("/"),
      segments: segments,
      query: parseRouteQuery(search),
      search: search,
      hash: hashRoute,
      href: String(global.location.href || "")
    };
  }

  function routeString(info) {
    info = info || currentRouteInfo();
    return info.path + (info.search ? "?" + info.search : "");
  }

  function currentRoutePath() {
    return routeString(currentRouteInfo());
  }

  function normalizedRoutePath(path) {
    var target = typeof path === "string" && path ? path : "/";
    if (target.charAt(0) !== "/") target = "/" + target;
    return target;
  }

  function hashRouteTarget(path) {
    var target = typeof path === "string" && path ? path : "/";
    if (target.charAt(0) === "#") target = target.slice(1);
    return "#" + normalizedRoutePath(target);
  }

  function syncRouteToVm(module, info) {
    if (!module || typeof module._mochi_set_route_state !== "function") return;
    info = info || currentRouteInfo();
    withUtf8(module, routeString(info), function (ptr, len) {
      module._mochi_set_route_state(ptr, len);
    });
    if (typeof module._mochi_set_route_info === "function") {
      withUtf8(module, JSON.stringify(info), function (ptr, len) {
        module._mochi_set_route_info(ptr, len);
      });
    }
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

  function storageErrorName(error) {
    var name = error && error.name ? String(error.name) : "";
    if (name === "QuotaExceededError" || name === "NS_ERROR_DOM_QUOTA_REACHED" ||
        (error && (error.code === 22 || error.code === 1014))) {
      return "quota";
    }
    return "unavailable";
  }

  function readStorageValue(key) {
    if (!key || !global.localStorage || typeof global.localStorage.getItem !== "function") {
      return { ok: false, value: null, error: "unavailable" };
    }
    try {
      var value = global.localStorage.getItem(key);
      return { ok: true, value: value === null ? null : String(value), error: "" };
    } catch (error) {
      return { ok: false, value: null, error: storageErrorName(error) };
    }
  }

  function writeStorageValue(key, value) {
    if (!key || !global.localStorage || typeof global.localStorage.setItem !== "function") {
      return { ok: false, error: "unavailable" };
    }
    try {
      global.localStorage.setItem(key, String(value));
      return { ok: true, error: "" };
    } catch (error) {
      return { ok: false, error: storageErrorName(error) };
    }
  }

  function removeStorageValue(key) {
    if (!key || !global.localStorage || typeof global.localStorage.removeItem !== "function") {
      return { ok: false, error: "unavailable" };
    }
    try {
      global.localStorage.removeItem(key);
      return { ok: true, error: "" };
    } catch (error) {
      return { ok: false, error: storageErrorName(error) };
    }
  }

  function syncStorageValueToVm(module, key, value) {
    if (!module || !key) return;
    if (value === null || value === undefined) {
      if (typeof module._mochi_remove_storage !== "function") return;
      withUtf8(module, key, function (pointer, length) {
        module._mochi_remove_storage(pointer, length);
      });
      return;
    }
    if (typeof module._mochi_seed_storage !== "function") return;
    withUtf8(module, key, function (keyPointer, keyLength) {
      withUtf8(module, String(value), function (valuePointer, valueLength) {
        module._mochi_seed_storage(keyPointer, keyLength, valuePointer, valueLength);
      });
    });
  }

  function storagePayload(key, value, previous, source, ok, error) {
    return {
      key: key,
      value: value === undefined ? null : value,
      previous: previous === undefined ? null : previous,
      source: source,
      ok: ok,
      error: error || ""
    };
  }

  function deliverStorageTo(info, instanceKey, callback) {
    var element = state.elements.get(String(instanceKey));
    if (!element || element._mochiDisconnected || element._mochiUnmounted) return false;
    if (!callback) return false;
    element._dispatchAction({ action: callback, payload: info, hasPayload: true });
    return true;
  }

  function notifyStorageChange(info) {
    var subscribers = state.storageSubscribers.get(info.key);
    if (!subscribers) return;
    Array.from(subscribers.entries()).forEach(function (record) {
      deliverStorageTo(info, record[0], record[1]);
    });
  }

  function globalEventSubscriptionKey(instance, mountToken, callback) {
    return String(instance) + "\u0000" + String(mountToken) + "\u0000" + callback;
  }

  function purgeGlobalEventDeliveries(instance, mountToken) {
    var owner = String(instance);
    state.globalEventQueue = state.globalEventQueue.filter(function (delivery) {
      var remove = delivery.record.instance === owner &&
        (mountToken === undefined || delivery.record.mountToken === mountToken);
      if (remove) state.globalEventQueueBytes -= delivery.bytes;
      return !remove;
    });
    if (state.globalEventQueueBytes < 0) state.globalEventQueueBytes = 0;
  }

  function purgeGlobalEventSubscription(eventName, subscriptionKey) {
    state.globalEventQueue = state.globalEventQueue.filter(function (delivery) {
      var key = globalEventSubscriptionKey(
        delivery.record.instance, delivery.record.mountToken, delivery.record.callback);
      var remove = delivery.eventName === eventName && key === subscriptionKey;
      if (remove) state.globalEventQueueBytes -= delivery.bytes;
      return !remove;
    });
    if (state.globalEventQueueBytes < 0) state.globalEventQueueBytes = 0;
  }

  function removeGlobalEventSubscriptions(instance, mountToken) {
    var owner = String(instance);
    state.globalEventSubscribers.forEach(function (subscribers, eventName) {
      subscribers.forEach(function (record, key) {
        if (record.instance === owner &&
            (mountToken === undefined || record.mountToken === mountToken)) {
          subscribers.delete(key);
        }
      });
      if (subscribers.size === 0) state.globalEventSubscribers.delete(eventName);
    });
    purgeGlobalEventDeliveries(owner, mountToken);
  }

  function registerGlobalEventSubscriber(entry, module) {
    var eventName = typeof entry.event === "string" ? entry.event : "";
    var callback = typeof entry.callback === "string" ? entry.callback : "";
    var instance = entry.instance === undefined || entry.instance === null
      ? ""
      : String(entry.instance);
    if (!eventName || eventName.length > 128 || !callback || callback.length > 128 || !instance) return;
    var element = state.elements.get(instance);
    if (!element || element._mochiDisconnected || element._mochiUnmounted ||
        (element._mochiMountState !== "mounted" && element._mochiMountState !== "mounting") ||
        String(element._mochiInstance) !== instance ||
        state.unmountedInstances.has(instance)) return;
    if (!hasMethod(module, element._mochiInstance, callback)) {
      reportError(element, "event", callback,
        new Error("mochi-loader: event subscriber method '" + callback + "' is not defined"), module);
      return;
    }
    var subscribers = state.globalEventSubscribers.get(eventName);
    if (!subscribers) {
      subscribers = new Map();
      state.globalEventSubscribers.set(eventName, subscribers);
    }
    var key = globalEventSubscriptionKey(instance, element._mochiMountToken, callback);
    if (subscribers.has(key)) return;
    subscribers.set(key, {
      instance: instance,
      mountToken: element._mochiMountToken,
      callback: callback,
    });
  }

  function unregisterGlobalEventSubscriber(entry) {
    var eventName = typeof entry.event === "string" ? entry.event : "";
    var callback = typeof entry.callback === "string" ? entry.callback : "";
    var instance = entry.instance === undefined || entry.instance === null
      ? ""
      : String(entry.instance);
    if (!eventName || !callback || !instance) return;
    var element = state.elements.get(instance);
    if (!element || element._mochiDisconnected || element._mochiUnmounted ||
        String(element._mochiInstance) !== instance) return;
    var subscribers = state.globalEventSubscribers.get(eventName);
    if (!subscribers) return;
    var key = globalEventSubscriptionKey(instance, element._mochiMountToken, callback);
    subscribers.delete(key);
    purgeGlobalEventSubscription(eventName, key);
    if (subscribers.size === 0) state.globalEventSubscribers.delete(eventName);
  }

  function globalEventQueueLimits() {
    var capacities = state.manifest && state.manifest.capacity_profile &&
      state.manifest.capacity_profile.capacities;
    return {
      entries: capacities ? capacities.host_event_queue_entries : 0,
      bytes: capacities ? capacities.host_event_queue_bytes : 0,
    };
  }

  function clearGlobalEventQueue() {
    state.globalEventQueue.length = 0;
    state.globalEventQueueBytes = 0;
  }

  function clearGlobalEventChain(chainId) {
    if (chainId === undefined || chainId === null) {
      clearGlobalEventQueue();
      return;
    }
    state.globalEventQueue = state.globalEventQueue.filter(function (delivery) {
      var remove = delivery.chainId === chainId;
      if (remove) state.globalEventQueueBytes -= delivery.bytes;
      return !remove;
    });
    if (state.globalEventQueueBytes < 0) state.globalEventQueueBytes = 0;
  }

  function globalEventErrorContext(delivery, eventName) {
    var record = delivery && delivery.record;
    var element = record ? state.elements.get(record.instance) : null;
    var origin = delivery && delivery.origin;
    if ((!element || element._mochiUnmounted) && origin && origin.element) {
      element = origin.element;
    }
    var method = record && record.callback;
    if (origin && origin.element && !origin.element._mochiUnmounted) {
      element = origin.element;
      method = origin.method || method;
    }
    return {
      element: element,
      method: method || "event",
      details: {
        event: eventName || delivery && delivery.eventName || "",
        subscriber: record ? record.instance : "",
        callback: record ? record.callback : "",
        publisher: delivery && delivery.publisher || "",
      },
    };
  }

  function failGlobalEventQueue(module, eventName, delivery, reason, chainId) {
    clearGlobalEventChain(chainId === undefined && delivery ? delivery.chainId : chainId);
    if (state.reportingGlobalEventOverflow) return;
    state.reportingGlobalEventOverflow = true;
    try {
      var context = globalEventErrorContext(delivery, eventName);
      var error = new Error("mochi-loader: global event delivery " + reason +
        " for '" + (eventName || "unknown") + "'");
      error.mochiContext = context.details;
      reportError(context.element, "event", context.method, error, module);
    } finally {
      state.reportingGlobalEventOverflow = false;
    }
  }

  function enqueueGlobalEvent(entry, module) {
    var eventName = typeof entry.event === "string" ? entry.event : "";
    if (!eventName) return;
    if (state.reportingGlobalEventOverflow) return;
    var subscribers = state.globalEventSubscribers.get(eventName);
    if (!subscribers) return;
    var origin = state.activeGlobalEventDelivery || state.activeActionContext;
    var chainId = state.activeGlobalEventDelivery
      ? state.activeGlobalEventDelivery.chainId
      : {};
    var hasPayload = Object.prototype.hasOwnProperty.call(entry, "payload");
    var payload = hasPayload ? entry.payload : null;
    var encodedPayload;
    try {
      encodedPayload = JSON.stringify(payload);
    } catch (_) {
      failGlobalEventQueue(module, eventName, null, "payload serialization failed", chainId);
      return;
    }
    if (encodedPayload === undefined) encodedPayload = "null";
    var bytes = encode(eventName + encodedPayload).length + 64;
    var limits = globalEventQueueLimits();
    var publisher = entry.instance === undefined || entry.instance === null
      ? ""
      : String(entry.instance);
    // Snapshot synchronously at publication time. Delivery is deferred until
    // the whole VM outbox has been queued, preserving sibling publish order.
    var deliveries = [];
    var failedDelivery = null;
    var capacityExceeded = false;
    subscribers.forEach(function (record, key) {
      if (capacityExceeded) return;
      if (subscribers.get(key) !== record) return;
      var element = state.elements.get(record.instance);
      if (!element || element._mochiDisconnected || element._mochiUnmounted ||
          element._mochiMountToken !== record.mountToken ||
          String(element._mochiInstance) !== record.instance) {
        subscribers.delete(key);
        return;
      }
      // Pending subscriptions survive publications during mount, but only
      // ready receivers join a publication's snapshot. Nothing is replayed.
      if (element._mochiMountState !== "mounted") return;
      var delivery = {
        eventName: eventName,
        record: record,
        payload: payload,
        hasPayload: hasPayload,
        publisher: publisher,
        origin: origin,
        chainId: chainId,
        bytes: bytes,
      };
      failedDelivery = delivery;
      if (!Number.isSafeInteger(limits.entries) || limits.entries <= 0 ||
          !Number.isSafeInteger(limits.bytes) || limits.bytes <= 0 ||
          state.globalEventQueue.length + deliveries.length + 1 > limits.entries ||
          state.globalEventQueueBytes + (deliveries.length + 1) * bytes > limits.bytes) {
        capacityExceeded = true;
        return;
      }
      deliveries.push(delivery);
    });
    if (subscribers.size === 0) state.globalEventSubscribers.delete(eventName);
    if (capacityExceeded) {
      failGlobalEventQueue(module, eventName, failedDelivery,
        "queue capacity exhausted", chainId);
      return;
    }
    if (deliveries.length === 0) return;
    deliveries.forEach(function (delivery) {
      state.globalEventQueue.push(delivery);
      state.globalEventQueueBytes += delivery.bytes;
    });
  }

  function queuedGlobalEventIsLive(delivery) {
    var subscribers = state.globalEventSubscribers.get(delivery.eventName);
    var key = globalEventSubscriptionKey(
      delivery.record.instance, delivery.record.mountToken, delivery.record.callback);
    if (!subscribers || subscribers.get(key) !== delivery.record) return false;
    var element = state.elements.get(delivery.record.instance);
    return Boolean(element && !element._mochiDisconnected && !element._mochiUnmounted &&
      element._mochiMountState === "mounted" &&
      element._mochiMountToken === delivery.record.mountToken &&
      String(element._mochiInstance) === delivery.record.instance);
  }

  function drainGlobalEventQueue(module) {
    if (state.globalEventQueueDraining || !state.globalEventQueue.length) return;
    state.globalEventQueueDraining = true;
    var limits = globalEventQueueLimits();
    var deliveriesByChain = new Map();
    try {
      while (state.globalEventQueue.length > 0) {
        var nextDelivery = state.globalEventQueue[0];
        var chainDeliveries = deliveriesByChain.get(nextDelivery.chainId) || 0;
        if (chainDeliveries >= limits.entries) {
          failGlobalEventQueue(module, nextDelivery.eventName,
            nextDelivery, "limit exhausted", nextDelivery.chainId);
          continue;
        }
        var delivery = state.globalEventQueue.shift();
        state.globalEventQueueBytes -= delivery.bytes;
        if (state.globalEventQueueBytes < 0) state.globalEventQueueBytes = 0;
        if (!queuedGlobalEventIsLive(delivery)) continue;
        var element = state.elements.get(delivery.record.instance);
        var previousDelivery = state.activeGlobalEventDelivery;
        state.activeGlobalEventDelivery = {
          element: element,
          method: delivery.record.callback,
          eventName: delivery.eventName,
          chainId: delivery.chainId,
          publisher: delivery.publisher,
          subscriber: delivery.record.instance,
          callback: delivery.record.callback,
        };
        deliveriesByChain.set(delivery.chainId, chainDeliveries + 1);
        try {
          element._dispatchAction({
            action: delivery.record.callback,
            payload: delivery.payload,
            hasPayload: delivery.hasPayload,
          });
        } finally {
          state.activeGlobalEventDelivery = previousDelivery;
        }
      }
    } finally {
      state.activeGlobalEventDelivery = null;
      state.globalEventQueueDraining = false;
      if (state.globalEventQueue.length === 0) state.globalEventQueueBytes = 0;
    }
  }

  function handleStorageEvent(event) {
    if (!event) return;
    var module = state.activeModule;
    if (event.key === null) {
      state.storageSubscribers.forEach(function (_subscribers, key) {
        var current = readStorageValue(key);
        if (current.ok) syncStorageValueToVm(module, key, current.value);
        notifyStorageChange(storagePayload(
          key, current.value, null, "external", current.ok, current.error));
      });
      return;
    }
    if (typeof event.key !== "string") return;
    var value = event.newValue === undefined || event.newValue === null
      ? null
      : String(event.newValue);
    var previous = event.oldValue === undefined || event.oldValue === null
      ? null
      : String(event.oldValue);
    syncStorageValueToVm(module, event.key, value);
    notifyStorageChange(storagePayload(event.key, value, previous, "external", true, ""));
  }

  function deliverRouteTo(info, instanceKey) {
    var element = state.elements.get(String(instanceKey));
    if (!element || element._mochiDisconnected || element._mochiUnmounted) return false;
    element._dispatchAction({ action: "on_route", payload: info, hasPayload: true });
    return true;
  }

  function notifyRouteChange(info) {
    info = info || currentRouteInfo();
    if (state.activeModule) syncRouteToVm(state.activeModule, info);
    if (state.routeSubscribers.size > 0) {
      Array.from(state.routeSubscribers).forEach(function (instanceKey) {
        deliverRouteTo(info, instanceKey);
      });
      return;
    }
    // Compatibility for apps that still implement `on_route` without the
    // explicit subscription API. New route hosts receive one structured
    // payload and do not depend on document-wide action fan-out.
    state.elements.forEach(function (element) {
      element._dispatchAction({ action: "on_route", payload: routeString(info), hasPayload: true });
    });
  }

  function ensureActionRouter() {
    if (state.actionRouterInstalled || !global.document) return;
    state.actionRouterInstalled = true;

    if (typeof global.addEventListener === "function") {
      global.addEventListener("popstate", function () {
        notifyRouteChange(currentRouteInfo());
      });
      global.addEventListener("hashchange", function () {
        notifyRouteChange(currentRouteInfo());
      });
      global.addEventListener("storage", function (event) {
        handleStorageEvent(event);
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
          typeof parsed.instance !== "string" || !Number.isFinite(parsed.id) || parsed.id <= 0) {
        return null;
      }
      if (parsed.cancel === true) {
        return { id: parsed.id, instance: parsed.instance, cancel: true };
      }
      if (typeof parsed.url !== "string" || typeof parsed.callback !== "string") return null;
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

  function fetchRequestKey(request) {
    return String(request.instance) + ":" + String(request.id);
  }

  function latestFetchKey(request) {
    return String(request.instance) + ":" + String(request.mountToken) + ":" +
      String(request.requestKey);
  }

  function forgetFetch(request) {
    state.activeFetches.delete(fetchRequestKey(request));
    if (request.requestKey !== undefined) {
      var key = latestFetchKey(request);
      if (state.latestFetches.get(key) === fetchRequestKey(request)) {
        state.latestFetches.delete(key);
      }
    }
  }

  function cancelFetch(request) {
    var key = fetchRequestKey(request);
    var active = state.activeFetches.get(key);
    if (active) {
      active.cancelled = true;
      var network = state.hostAdapters.get("network");
      if (network && network.sync && typeof network.sync.cancel === "function") {
        network.sync.cancel(fetchRequestKey(request), network.limits);
      }
      forgetFetch(active.request);
    }
    state.pendingFetches = state.pendingFetches.filter(function (pending) {
      return fetchRequestKey(pending) !== key;
    });
  }

  function cancelOwnerFetches(instance) {
    state.activeFetches.forEach(function (active) {
      if (String(active.request.instance) === String(instance)) {
        cancelFetch(active.request);
      }
    });
    state.pendingFetches = state.pendingFetches.filter(function (request) {
      return String(request.instance) !== String(instance);
    });
  }

  function cancelOwnerPointerCaptures(instance, mountToken) {
    var adapter = state.hostAdapters.get("pointer");
    if (adapter && typeof adapter.disposeOwner === "function") {
      adapter.disposeOwner(String(instance), mountToken);
    }
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
    var active = state.activeFetches.get(fetchRequestKey(request));
    if (active && active.cancelled) return;
    var liveElement = fetchElement(request);
    if (!liveElement || liveElement !== element) return;
    forgetFetch(request);
    try {
      writeFetchEnvelope(module, element, request, envelope);
      if (!element._mochiDisconnected) {
        applyPatches(element, module);
        drainEmits(module);
        drainFetches(module);
      }
    } catch (error) {
      discardHostOutboxes(module);
      reportError(element, "fetch", request && request.callback, error, module);
    }
  }

  function startFetch(module, request, element) {
    // Capture the mount attempt so a response that arrives after disposal
    // cannot reach a later component that reused the VM instance slot.
    request.mountToken = element._mochiMountToken;
    var options = request.options && typeof request.options === "object" ? request.options : {};
    request.requestKey = typeof options.key === "string" ? options.key :
      (typeof options.request_key === "string" ? options.request_key : undefined);
    if (request.requestKey !== undefined) {
      var latestKey = latestFetchKey(request);
      var previousKey = state.latestFetches.get(latestKey);
      if (previousKey !== undefined) {
        var previous = state.activeFetches.get(previousKey);
        if (previous) cancelFetch(previous.request);
        else state.latestFetches.delete(latestKey);
      }
      state.latestFetches.set(latestKey, fetchRequestKey(request));
    }
    var pendingLimit = capabilityLimit(state.manifest, "network", "pending_requests");
    if (state.activeFetches.size >= pendingLimit) {
      deliverFetch(module, element, request, {
        status: 0, ok: false, body: "", data: null,
        error: "network request capacity exceeded (capacity " + pendingLimit + ")"
      });
      return;
    }
    var active = { request: request, cancelled: false };
    state.activeFetches.set(fetchRequestKey(request), active);
    var adapter = state.hostAdapters.get("network");
    var operation = adapter && adapter.async && adapter.async.fetch;
    if (typeof operation !== "function") {
      deliverFetch(module, element, request, {
        status: 0, ok: false, body: "", data: null,
        error: "network capability is not loaded for this component"
      });
      return;
    }
    var responsePromise;
    try {
      responsePromise = operation.call(adapter.async, JSON.stringify({
        request_key: fetchRequestKey(request), url: request.url, options: options
      }), adapter.limits);
    } catch (error) {
      deliverFetch(module, element, request, {
        status: 0, ok: false, body: "", data: null,
        error: error && error.message ? error.message : String(error)
      });
      return;
    }
    Promise.resolve(responsePromise).then(function (envelope) {
      if (active.cancelled || !fetchElement(request)) return;
      deliverFetch(module, element, request, envelope);
    }, function (error) {
      if (active.cancelled || !fetchElement(request)) return;
      deliverFetch(module, element, request, {
        status: 0, ok: false, body: "", data: null,
        error: error && error.message ? error.message : String(error)
      });
    }).finally(function () {
      if (active.cancelled) forgetFetch(request);
    });
  }

  function hostRequestKey(request) {
    return String(request.instance) + ":" + String(request.id);
  }

  function hostRequestElement(request) {
    var element = state.elements.get(String(request.instance));
    if (!element || element._mochiDisconnected || element._mochiUnmounted) return null;
    if (request.mountToken !== undefined && element._mochiMountToken !== request.mountToken) {
      return null;
    }
    return element;
  }

  function writeHostResult(module, element, request, envelope) {
    var offset = module._mochi_host_inbox_offset ? module._mochi_host_inbox_offset() : 0;
    var capacity = module._mochi_host_inbox_capacity ? module._mochi_host_inbox_capacity() : 0;
    var bytes = encode(JSON.stringify(envelope));
    if (!offset || capacity <= 0 || bytes.length + 1 > capacity) {
      throw new Error("mochi-loader: host capability response exceeds inbox capacity");
    }
    module.HEAPU8.set(bytes, offset);
    var delivered = false;
    withUtf8(module, request.callback, function (pointer, length) {
      delivered = module._mochi_deliver_host_result(
        element._mochiInstance, pointer, length, bytes.length) === 0;
    });
    if (!delivered) {
      throw new Error("mochi-loader: host capability callback failed for " +
        request.callback + ": " + lastError(module));
    }
  }

  function deliverHostResult(module, element, request, envelope) {
    state.pendingHostRequests.delete(hostRequestKey(request));
    var liveElement = hostRequestElement(request);
    if (!liveElement || liveElement !== element) return;
    try {
      writeHostResult(module, element, request, envelope);
      if (!element._mochiDisconnected) {
        applyPatches(element, module);
        drainEmits(module);
        drainFetches(module);
      }
    } catch (error) {
      discardHostOutboxes(module);
      reportError(element, "capability", request && request.callback, error, module);
    }
  }

  // An async adapter request carries the live mount attempt. A result that
  // arrives after disposal or a replacement mount is dropped instead of
  // reaching a different component that reused the VM instance slot.
  function startHostCapability(module, entry) {
    var request = {
      id: entry.id,
      instance: entry.instance,
      capability: typeof entry.capability === "string" ? entry.capability : "",
      operation: typeof entry.operation === "string" ? entry.operation : "",
      callback: typeof entry.callback === "string" ? entry.callback : ""
    };
    var element = hostRequestElement(request);
    if (!element) return;
    request.mountToken = element._mochiMountToken;

    var adapter = state.hostAdapters.get(request.capability);
    var operation = adapter && adapter.async && adapter.async[request.operation];
    if (typeof operation !== "function") {
      deliverHostResult(module, element, request, {
        ok: false,
        value: null,
        error: "host capability '" + request.capability + "' has no async operation '" +
          request.operation + "'"
      });
      return;
    }

    state.pendingHostRequests.set(hostRequestKey(request), request);
    var argsJson;
    try {
      argsJson = JSON.stringify(entry.args === undefined ? [] : entry.args);
    } catch (error) {
      deliverHostResult(module, element, request, {
        ok: false,
        value: null,
        error: "host capability arguments are not serializable: " +
          (error && error.message ? error.message : String(error))
      });
      return;
    }

    var result;
    try {
      result = operation.call(adapter.async, argsJson, adapter.limits);
    } catch (error) {
      deliverHostResult(module, element, request, {
        ok: false,
        value: null,
        error: error && error.message ? error.message : String(error)
      });
      return;
    }

    Promise.resolve(result).then(function (value) {
      deliverHostResult(module, element, request, {
        ok: true,
        value: value === undefined ? null : value,
        error: null
      });
    }, function (error) {
      deliverHostResult(module, element, request, {
        ok: false,
        value: null,
        error: error && error.message ? error.message : String(error)
      });
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
    var pendingLimit = capabilityLimit(state.manifest, "network", "pending_requests");
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
      if (request.cancel) {
        cancelFetch(request);
        return;
      }
      var element = fetchElement(request);
      if (element) {
        startFetch(module, request, element);
        return;
      }
      if (!state.unmountedInstances.has(String(request.instance))
          && state.activeFetches.size + state.pendingFetches.length < pendingLimit) {
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

  function pointerCommandTarget(element, reference, currentTarget) {
    var root = element && element.shadowRoot;
    var target = reference ? findNamedRef(element, reference) : currentTarget;
    if (!root || !target || !target.isConnected || !root.contains(target)) {
      throw new Error("mochi-pointer: target is stale or not owned by this component mount");
    }
    return target;
  }

  function pointerMoveKey(element, pointerId) {
    return String(element._mochiMountToken) + ":" + String(pointerId);
  }

  function flushPointerMove(element, pointerId) {
    var key = pointerMoveKey(element, pointerId);
    var pending = state.pointerMoves.get(key);
    if (!pending) return;
    state.pointerMoves.delete(key);
    if (pending.frame !== null) {
      if (pending.frameKind === "animation" && typeof global.cancelAnimationFrame === "function") {
        global.cancelAnimationFrame(pending.frame);
      } else {
        global.clearTimeout(pending.frame);
      }
    }
    if (!element._mochiUnmounted && pending.mountToken === element._mochiMountToken &&
        pending.target && pending.target.isConnected) {
      element._dispatch(pending.target, pending.event, true);
    }
  }

  function queuePointerMove(element, target, event) {
    var key = pointerMoveKey(element, event.pointerId);
    var pending = state.pointerMoves.get(key);
    if (pending) {
      pending.target = target;
      pending.event = event;
      return;
    }
    pending = {
      element: element,
      target: target,
      event: event,
      mountToken: element._mochiMountToken,
      frame: null,
      frameKind: "timeout",
    };
    state.pointerMoves.set(key, pending);
    var flush = function () {
      flushPointerMove(element, event.pointerId);
    };
    if (typeof global.requestAnimationFrame === "function") {
      pending.frameKind = "animation";
      pending.frame = global.requestAnimationFrame(flush);
    } else {
      pending.frame = global.setTimeout(flush, 16);
    }
  }

  function discardPointerMoves(element, liveRoot) {
    Array.from(state.pointerMoves.values()).forEach(function (pending) {
      if (pending.element !== element) return;
      if (liveRoot && liveRoot.contains(pending.target)) return;
      state.pointerMoves.delete(pointerMoveKey(element, pending.event.pointerId));
      if (pending.frame === null) return;
      if (pending.frameKind === "animation" && typeof global.cancelAnimationFrame === "function") {
        global.cancelAnimationFrame(pending.frame);
      } else {
        global.clearTimeout(pending.frame);
      }
    });
  }

  function pointerReason(event) {
    if (!event) return "";
    if (event.type === "pointerup") return "up";
    if (event.type === "pointercancel") return "cancel";
    if (event.type === "lostpointercapture") return "lost_capture";
    return "";
  }

  function handlePointerCommand(module, entry, operation) {
    var ownerKey = typeof entry.instance === "string" ? entry.instance : "";
    var element = state.elements.get(ownerKey);
    var pointerId = Number(entry.pointer_id);
    var reference = typeof entry.reference === "string" ? entry.reference : "";
    if (!element || element._mochiDisconnected || element._mochiUnmounted ||
        !element.isConnected || String(element._mochiInstance) !== ownerKey) {
      throw new Error("mochi-pointer: component mount is stale or no longer live");
    }
    var adapter = state.hostAdapters.get("pointer");
    if (!adapter || !adapter.sync || typeof adapter.sync[operation] !== "function") {
      throw new Error("mochi-pointer: pointer capability is not loaded for this component");
    }
    if (operation === "capture") {
      var context = state.activePointerDispatch;
      if (!context || context.element !== element || context.mountToken !== element._mochiMountToken ||
          !context.event || context.event.pointerId !== pointerId ||
          typeof context.event.buttons !== "number" || context.event.buttons === 0) {
        throw new Error("mochi-pointer: capture requires the matching active pointer event");
      }
      var target = pointerCommandTarget(element, reference, context.target);
      adapter.sync.capture(
        target, pointerId, ownerKey, element._mochiMountToken, context.event, adapter.limits
      );
      return;
    }
    if (operation === "release") {
      var releaseTarget = reference
        ? pointerCommandTarget(element, reference, null)
        : null;
      adapter.sync.release(
        pointerId, ownerKey, element._mochiMountToken, releaseTarget, adapter.limits
      );
    }
  }

  function handleDragCommand(module, entry) {
    var ownerKey = typeof entry.instance === "string" ? entry.instance : "";
    var element = state.elements.get(ownerKey);
    var context = state.activeDragDispatch;
    var adapter = state.hostAdapters.get("drag");
    if (!element || element._mochiDisconnected || element._mochiUnmounted ||
        !element.isConnected || String(element._mochiInstance) !== ownerKey ||
        !context || context.element !== element || context.mountToken !== element._mochiMountToken) {
      throw new Error("mochi-drag: component mount or native drag event is stale");
    }
    if (!adapter || !adapter.sync) throw new Error("mochi-drag: drag capability is not loaded");
    if (entry.__host === "drag_set_data") {
      adapter.sync.set_data(context, entry.value, adapter.limits);
    } else if (entry.__host === "drag_set_text") {
      adapter.sync.set_text(context, entry.value, adapter.limits);
    } else if (entry.__host === "drag_accept") {
      adapter.sync.accept(context, String(entry.type || ""), String(entry.effect || "copy"));
    }
  }

  function handleHostCommand(module, entry) {
    var hostKind = entry.__host;
    if (hostKind === "pointer_capture") {
      handlePointerCommand(module, entry, "capture");
      return;
    }
    if (hostKind === "pointer_release") {
      handlePointerCommand(module, entry, "release");
      return;
    }
    if (hostKind === "drag_set_data" || hostKind === "drag_set_text" || hostKind === "drag_accept") {
      handleDragCommand(module, entry);
      return;
    }
    if (hostKind === "storage_set") {
      var setKey = typeof entry.key === "string" ? entry.key : "";
      var setValue = String(entry.value !== undefined ? entry.value : "");
      var previous = readStorageValue(setKey);
      if (previous.ok && previous.value === setValue) return;
      var written = writeStorageValue(setKey, setValue);
      if (!written.ok) {
        var fallback = previous.ok ? previous.value : null;
        syncStorageValueToVm(module, setKey, fallback);
        notifyStorageChange(storagePayload(
          setKey, fallback, previous.value, "same_tab", false, written.error));
        reportError(null, "storage", "storage_set", new Error(written.error));
        return;
      }
      notifyStorageChange(storagePayload(
        setKey, setValue, previous.value, "same_tab", true, ""));
      return;
    }
    if (hostKind === "storage_remove") {
      var removeKey = typeof entry.key === "string" ? entry.key : "";
      var removed = readStorageValue(removeKey);
      if (removed.ok && removed.value === null) return;
      var deletion = removeStorageValue(removeKey);
      if (!deletion.ok) {
        var kept = removed.ok ? removed.value : null;
        syncStorageValueToVm(module, removeKey, kept);
        notifyStorageChange(storagePayload(
          removeKey, kept, removed.value, "same_tab", false, deletion.error));
        reportError(null, "storage", "storage_remove", new Error(deletion.error));
        return;
      }
      notifyStorageChange(storagePayload(
        removeKey, null, removed.value, "same_tab", true, ""));
      return;
    }
    if (hostKind === "storage_subscribe") {
      var subscribeKey = typeof entry.key === "string" ? entry.key : "";
      var callback = typeof entry.callback === "string" ? entry.callback : "";
      var subscriber = entry.instance === undefined || entry.instance === null
        ? ""
        : String(entry.instance);
      if (!subscribeKey || !callback || !subscriber) return;
      var storageElement = state.elements.get(subscriber);
      if (!storageElement || storageElement._mochiDisconnected || storageElement._mochiUnmounted ||
          String(storageElement._mochiInstance) !== subscriber) return;
      var bucket = state.storageSubscribers.get(subscribeKey);
      if (!bucket) {
        bucket = new Map();
        state.storageSubscribers.set(subscribeKey, bucket);
      }
      bucket.set(subscriber, callback);
      var current = readStorageValue(subscribeKey);
      if (current.ok) syncStorageValueToVm(module, subscribeKey, current.value);
      deliverStorageTo(storagePayload(
        subscribeKey, current.value, null, "initial", current.ok, current.error),
        subscriber, callback);
      return;
    }
    if (hostKind === "event_subscribe") {
      registerGlobalEventSubscriber(entry, module);
      return;
    }
    if (hostKind === "event_unsubscribe") {
      unregisterGlobalEventSubscriber(entry);
      return;
    }
    if (hostKind === "event_publish") {
      enqueueGlobalEvent(entry, module);
      return;
    }
    if (hostKind === "set_route" || hostKind === "replace_route") {
      var path = typeof entry.path === "string" ? entry.path : "/";
      var replace = hostKind === "replace_route";
      var hashMode = currentRouteInfo().hash || path.charAt(0) === "#";
      var targetUrl = hashMode ? hashRouteTarget(path) : normalizedRoutePath(path);
      try {
        if (global.history) {
          var method = replace ? "replaceState" : "pushState";
          if (typeof global.history[method] === "function") {
            global.history[method]({ __mochiRoute: true }, "", targetUrl);
          }
        }
      } catch (error) {
        reportError(null, "route", hostKind, error);
      }
      notifyRouteChange(currentRouteInfo());
      return;
    }
    if (hostKind === "route_subscribe") {
      var subscriber = entry.instance === undefined || entry.instance === null
        ? ""
        : String(entry.instance);
      if (!subscriber) return;
      var routeElement = state.elements.get(subscriber);
      if (!routeElement || routeElement._mochiDisconnected || routeElement._mochiUnmounted ||
          String(routeElement._mochiInstance) !== subscriber) return;
      state.routeSubscribers.add(subscriber);
      deliverRouteTo(currentRouteInfo(), subscriber);
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
    if (hostKind === "capability_async") {
      startHostCapability(module, entry);
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
      if (!liveElement || liveElement._mochiDisconnected || liveElement._mochiUnmounted ||
          String(liveElement._mochiInstance) !== instanceKey) return;
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
          discardHostOutboxes(module);
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
    if (length < 0) {
      discardHostOutboxes(module);
      throw new Error("mochi-loader: host command batch failed: " + lastError(module));
    }
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
        if (entry.__host === "event_publish") {
          enqueueGlobalEvent(entry, module);
          return;
        }
        // Finish preceding global publications before applying the next host
        // command, so route/storage/focus commands keep their established
        // position relative to Ruby publications.
        drainGlobalEventQueue(module);
        handleHostCommand(module, entry);
        return;
      }
      if (typeof entry.__child_event === "string") {
        drainGlobalEventQueue(module);
        deliverChildEvent(module, entry);
        return;
      }
    });
    drainGlobalEventQueue(module);
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

      assertCapacityProfile(module, state.manifest);

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

    // Fetch packages concurrently. Only the VM's synchronous irep load needs
    // serialization; keeping network waits on this chain lets one slow sibling
    // package stall unrelated components before their first render.
    var promise = (async function () {
      var module = await loadRuntime(manifest, manifestUrl);
      var response = await global.fetch(url);
      if (!response.ok) throw new Error("mochi-loader: failed to fetch " + url);

      var stripped = new Uint8Array(await response.arrayBuffer());
      var bytes = new Uint8Array(RITE_HEADER.length + stripped.length);
      bytes.set(RITE_HEADER, 0);
      bytes.set(stripped, RITE_HEADER.length);

      var loadTask = state.loadChain.then(function () {
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

      state.loadChain = loadTask.catch(function () {});
      return loadTask;
    })();
    state.irepPromises.set(url, promise);
    promise.catch(function () { state.irepPromises.delete(url); });
    return promise;
  }

  // The entry manifest is an index: it names each component and where its
  // descriptor lives. A descriptor carries the template, styles, bindings,
  // props, and dependency ids. It is fetched on first use, cached immutably,
  // and evicted from the promise map when it fails so a later mount can retry.
  function componentDescriptorUrl(entry, manifestUrl) {
    var path = entry.descriptor || (COMPONENT_DIR + entry.tag_name + ".json");
    return absoluteUrl(path, manifestUrl);
  }

  function validateComponentDescriptor(descriptor, entry, url, manifest) {
    var tag = entry.tag_name || "<unknown>";
    if (!descriptor || typeof descriptor !== "object" || Array.isArray(descriptor)) {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' must be an object (" + url + ")");
    }
    if (descriptor.schema_version !== MANIFEST_SCHEMA_VERSION) {
      throw new Error("mochi-loader: component descriptor for '" + tag + "' uses schema " +
        JSON.stringify(descriptor.schema_version) + " but this loader supports schema " +
        MANIFEST_SCHEMA_VERSION + " (" + url + ")");
    }
    if (descriptor.tag_name && descriptor.tag_name !== tag) {
      throw new Error("mochi-loader: descriptor for component '" + tag +
        "' declares tag '" + descriptor.tag_name + "' (" + url + ")");
    }
    if (typeof descriptor.class_name !== "string" || descriptor.class_name.length === 0) {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' has no class name (" + url + ")");
    }
    if (descriptor.html_template !== undefined && typeof descriptor.html_template !== "string") {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' has an invalid template (" + url + ")");
    }
    if (descriptor.bindings !== undefined && !Array.isArray(descriptor.bindings)) {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' has invalid bindings (" + url + ")");
    }
    if (descriptor.events !== undefined && !Array.isArray(descriptor.events)) {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' has invalid events (" + url + ")");
    }
    if (descriptor.style_resources !== undefined && !Array.isArray(descriptor.style_resources)) {
      throw new Error("mochi-loader: descriptor for component '" + tag + "' has invalid style resources (" + url + ")");
    }
    if (manifest && manifest.schema_version !== descriptor.schema_version) {
      throw new Error("mochi-loader: component descriptor for '" + tag +
        "' does not match the entry manifest schema (" + url + ")");
    }
    return descriptor;
  }

  // Ruby's icon helper emits a compiler-owned marker instead of a route-
  // relative URL. Resolve markers while loading descriptors or inserting
  // trusted Ruby markup; rendered DOM is never scanned or rewritten. Resource
  // paths are owned by the manifest and resolve beside it, like styles,
  // bytecode, and adapters.
  function resolveIconAssetReferences(markup, manifest, manifestUrl) {
    return String(markup).replace(/__MOCHI_ICON__([a-z0-9][a-z0-9-]*)__/g, function (reference, name) {
      var id = "icon:" + name;
      var resources = manifest && manifest.resources;
      var resource = resources && resources[id];
      if (!resource || resource.kind !== "icon" || typeof resource.file !== "string") {
        throw new Error("component references missing icon resource " + id);
      }
      return absoluteUrl(resource.file, manifestUrl);
    });
  }

  function resolveDescriptorAssetReferences(descriptor, manifest, manifestUrl) {
    function resolveTemplate(template) {
      return resolveIconAssetReferences(template, manifest, manifestUrl);
    }
    function resolveBindings(bindings) {
      (bindings || []).forEach(function (binding) {
        (binding.branches || []).forEach(function (branch) {
          if (typeof branch.html_template === "string") {
            branch.html_template = resolveTemplate(branch.html_template);
          }
          resolveBindings(branch.bindings);
        });
      });
    }
    if (typeof descriptor.html_template === "string") {
      descriptor.html_template = resolveTemplate(descriptor.html_template);
    }
    resolveBindings(descriptor.bindings);
    return descriptor;
  }

  function loadComponentDescriptor(entry, manifest, manifestUrl) {
    var url = componentDescriptorUrl(entry, manifestUrl);
    var existing = state.descriptorPromises.get(url);
    if (existing) return existing;

    var promise = global.fetch(url).then(function (response) {
      if (!response.ok) {
        throw new Error("mochi-loader: failed to fetch descriptor for component '" +
          entry.tag_name + "' from " + url +
          (response.status ? " (HTTP " + response.status + ")" : ""));
      }
      return response.json();
    }).then(function (descriptor) {
      return resolveDescriptorAssetReferences(
        validateComponentDescriptor(descriptor, entry, url, manifest),
        manifest,
        manifestUrl
      );
    }).then(function (descriptor) {
      var styleIds = descriptor.style_resources || [];
      return Promise.all(styleIds.map(function (id) {
        return loadStyleResource(id, manifest, manifestUrl, descriptor.tag_name || entry.tag_name);
      })).then(function () {
        return Object.assign({}, entry, descriptor, { descriptor: entry.descriptor });
      });
    }).catch(function (error) {
      state.descriptorPromises.delete(url);
      if (error && typeof error === "object") error.mochiPhase = "descriptor";
      throw error;
    });

    state.descriptorPromises.set(url, promise);
    return promise;
  }

  function styleResource(id, manifest) {
    var resources = manifest && manifest.resources;
    var resource = resources && resources[id];
    if (!resource || resource.kind !== "style") {
      throw new Error("component references missing style resource " + id);
    }
    return resource;
  }

  function loadStyleResource(id, manifest, manifestUrl, tag) {
    if (state.styleTextCache.has(id)) {
      return Promise.resolve(state.styleTextCache.get(id));
    }
    var existing = state.styleTextPromises.get(id);
    if (existing) return existing;

    var resource;
    try {
      resource = styleResource(id, manifest);
    } catch (error) {
      return Promise.reject(new Error(
        (tag || "component") + " references missing style resource " + id));
    }
    if (typeof resource.text === "string") {
      state.styleTextCache.set(id, resource.text);
      return Promise.resolve(resource.text);
    }
    if (!resource.file) {
      return Promise.reject(new Error(
        (tag || "component") + " style resource " + id + " has no file"));
    }

    var url = absoluteUrl(resource.file, manifestUrl);
    var promise = global.fetch(url).then(function (response) {
      if (!response.ok) {
        throw new Error("mochi-loader: failed to fetch style resource '" + id +
          "' for " + (tag || "component") + " from " + url);
      }
      return response.text();
    }).then(function (text) {
      state.styleTextCache.set(id, text);
      return text;
    }).catch(function (error) {
      state.styleTextPromises.delete(id);
      throw error;
    });

    state.styleTextPromises.set(id, promise);
    return promise;
  }

  // Optional host adapters register a typed operation table before a
  // component can call them from initialize or its first binding. The
  // manifest names each adapter and whether its operations are synchronous or
  // asynchronous; the promise map keeps concurrent mounts to one request.
  function localAdapterLocation(host) {
    if (typeof host !== "string" || host.length === 0) return false;
    // Capability adapters are local build artifacts. Reject schemes and
    // protocol-relative URLs so a manifest cannot pull code from a CDN.
    if (/^[a-z][a-z0-9+.-]*:/i.test(host)) return false;
    return host.indexOf("//") !== 0;
  }

  function capabilityEntry(manifest, name) {
    if (!manifest) return null;
    var entry = manifest.capabilities && manifest.capabilities[name];
    if (entry) return entry;
    if (name === "formatting" && manifest.format_host) {
      return {
        version: 1,
        host: manifest.format_host,
        operations: { format: "sync" },
        packages: [],
        limits: { cache_entries: manifest.capacity_profile.capacities.host_format_cache_entries }
      };
    }
    return null;
  }

  function capabilityLimit(manifest, name, key) {
    var capability = capabilityEntry(manifest, name);
    return capability && capability.limits && capability.limits[key];
  }

  function capabilityOperations(capability) {
    var operations = capability && capability.operations;
    if (operations && typeof operations === "object" && !Array.isArray(operations)) {
      return operations;
    }
    // Bundles from before operation metadata still have the one synchronous
    // formatting operation. New capabilities always declare their table.
    return capability && capability.host ? { format: "sync" } : {};
  }

  function componentCapabilities(component) {
    var names = [];
    if (component && Array.isArray(component.capabilities)) {
      component.capabilities.forEach(function (name) {
        if (typeof name === "string" && names.indexOf(name) === -1) names.push(name);
      });
    }
    if (component && component.formatting === true && names.indexOf("formatting") === -1) {
      names.push("formatting");
    }
    return names.sort();
  }

  function ensureHostAdapterRegistrar() {
    var existing = global.MochiHostAdapter;
    if (existing && existing.__mochiLoaderRegistrar === true) return;
    global.MochiHostAdapter = {
      __mochiLoaderRegistrar: true,
      register: function (spec) {
        var url = "";
        if (global.document && global.document.currentScript) {
          url = global.document.currentScript.src || "";
        }
        if (!url) url = state.loadingHostAdapterUrl || "";
        var registrations = state.hostAdapterRegistrations.get(url);
        if (!registrations) {
          registrations = [];
          state.hostAdapterRegistrations.set(url, registrations);
        }
        registrations.push(spec);
      }
    };
  }

  function hostAdapterError(name, host, tag, detail) {
    var label = tag ? " for " + tag : "";
    var error = new Error("mochi-loader: host capability '" + name +
      "' (" + host + ")" + label + ": " + detail);
    error.mochiCapability = name;
    error.mochiPhase = "capability";
    return error;
  }

  function validateHostAdapterSpec(spec, name, capability, url) {
    if (!spec || typeof spec !== "object") {
      throw new Error("adapter " + url + " did not register a capability object");
    }
    if (spec.name !== name) {
      throw new Error("adapter " + url + " registered as '" + spec.name +
        "' instead of '" + name + "'");
    }
    if (spec.version !== capability.version) {
      throw new Error("adapter " + url + " registers version " + spec.version +
        " but the manifest requires version " + capability.version);
    }
    if (spec.disposeOwner !== undefined && typeof spec.disposeOwner !== "function") {
      throw new Error("adapter " + url + " has an invalid owner disposal hook");
    }
    if (spec.reconcileOwner !== undefined && typeof spec.reconcileOwner !== "function") {
      throw new Error("adapter " + url + " has an invalid owner reconciliation hook");
    }

    var operations = capabilityOperations(capability);
    var declared = Object.keys(operations).sort();
    ["sync", "async"].forEach(function (mode) {
      var group = spec[mode];
      if (group === undefined) return;
      if (!group || typeof group !== "object" || Array.isArray(group)) {
        throw new Error("adapter " + url + " has an invalid " + mode + " table");
      }
      Object.keys(group).forEach(function (operation) {
        if (!Object.prototype.hasOwnProperty.call(operations, operation)) {
          throw new Error("adapter " + url + " registers undeclared operation '" +
            operation + "'");
        }
        if (operations[operation] !== mode) {
          throw new Error("adapter " + url + " registers operation '" + operation +
            "' as " + mode + " but the manifest declares " + operations[operation]);
        }
        if (typeof group[operation] !== "function") {
          throw new Error("adapter " + url + " operation '" + operation +
            "' is not a function");
        }
      });
    });
    declared.forEach(function (operation) {
      var mode = operations[operation];
      var group = spec[mode];
      if (!group || typeof group[operation] !== "function") {
        throw new Error("adapter " + url + " is missing " + mode +
          " operation '" + operation + "'");
      }
    });
    return spec;
  }

  function installHostAdapter(module, name, capability, spec, url) {
    var hosts = module.__mochiHostCapabilities;
    if (!hosts) {
      hosts = Object.create(null);
      module.__mochiHostCapabilities = hosts;
    }
    var existing = hosts[name];
    if (existing) {
      if (existing.version !== spec.version) {
        throw new Error("host capability '" + name + "' is already registered at version " +
          existing.version + ", not " + spec.version);
      }
      return existing;
    }
    var limits = Object.freeze(Object.assign({}, capability.limits || {}));
    if (spec.sync) Object.freeze(spec.sync);
    if (spec.async) Object.freeze(spec.async);
    var installedSpec = Object.freeze({
      name: spec.name,
      version: spec.version,
      sync: spec.sync,
      async: spec.async,
      disposeOwner: spec.disposeOwner,
      reconcileOwner: spec.reconcileOwner,
      snapshot: spec.snapshot,
      internalType: spec.internalType,
      limits: limits
    });
    hosts[name] = installedSpec;
    state.hostAdapters.set(name, installedSpec);
    return installedSpec;
  }

  async function loadHostAdapter(module, name, capability, manifest, manifestUrl, tag) {
    var url = absoluteUrl(capability.host, manifestUrl);
    var hosts = module.__mochiHostCapabilities;
    var installed = hosts && hosts[name];
    if (installed) {
      if (installed.version !== capability.version) {
        throw hostAdapterError(name, capability.host, tag,
          "registered version " + installed.version + " does not match manifest version " +
          capability.version);
      }
      return installed;
    }

    var existing = state.hostModulePromises.get(url);
    if (existing) {
      await existing;
      return module.__mochiHostCapabilities[name];
    }

    var promise = (async function () {
      ensureHostAdapterRegistrar();
      state.loadingHostAdapterUrl = url;
      var returned = null;
      try {
        if (loader.hostModuleFactory) {
          returned = await loader.hostModuleFactory(url);
        } else {
          await loadScript(url);
        }
      } finally {
        state.loadingHostAdapterUrl = null;
      }

      var registrations = state.hostAdapterRegistrations.get(url) || [];
      state.hostAdapterRegistrations.delete(url);
      if (returned && typeof returned === "object") registrations = registrations.concat([returned]);
      if (registrations.length === 0) {
        throw new Error("adapter " + url + " did not register a capability");
      }

      var installedSpec = null;
      registrations.forEach(function (spec) {
        var specName = spec && spec.name;
        var declared = capabilityEntry(manifest, specName);
        if (!declared || !declared.host ||
            absoluteUrl(declared.host, manifestUrl) !== url) {
          throw new Error("adapter " + url + " registered unknown capability '" +
            specName + "'");
        }
        validateHostAdapterSpec(spec, specName, declared, url);
        var installed = installHostAdapter(module, specName, declared, spec, url);
        if (specName === name) installedSpec = installed;
      });
      if (!installedSpec) {
        throw new Error("adapter " + url + " did not register capability '" + name + "'");
      }
      return installedSpec;
    })().catch(function (error) {
      state.hostModulePromises.delete(url);
      state.hostAdapterRegistrations.delete(url);
      throw hostAdapterError(name, capability.host, tag,
        error && error.message ? error.message : String(error));
    });

    state.hostModulePromises.set(url, promise);
    return promise;
  }

  async function ensureHostAdapters(component, manifest, manifestUrl) {
    var tag = component.tag_name || component.class_name || "component";
    var names = componentCapabilities(component);
    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      var capability = capabilityEntry(manifest, name);
      if (!capability) {
        throw hostAdapterError(name, "(missing)", tag,
          "the manifest does not declare this capability");
      }
      if (!capability.host) continue;
      var module = await loadRuntime(manifest, manifestUrl);
      await loadHostAdapter(module, name, capability, manifest, manifestUrl, tag);
    }
    return state.activeModule;
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
        var name = String(id).replace(/^capability:/, "");
        var capability = capabilityEntry(manifest, name);
        if (!capability) {
          throw hostAdapterError(name, "(missing)", null,
            "the manifest does not declare this capability");
        }
        if (!capability.host) return null;
        return loadRuntime(manifest, manifestUrl).then(function (module) {
          return loadHostAdapter(module, name, capability, manifest, manifestUrl, name);
        });
      }
      if (!descriptor.file) {
        throw new Error("mochi-loader: package '" + id + "' has no bytecode file");
      }
      return loadIrepUrl(chiUrl(descriptor.file, manifestUrl), id, manifest, manifestUrl);
    });
  }

  async function loadComponentClass(component, manifest, manifestUrl) {
    await ensureHostAdapters(component, manifest, manifestUrl);

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
      discardHostOutboxes(module);
      throw new Error("mochi-loader: mount failed for " + component.class_name + ": " + lastError(module));
    }

    // Mount hooks can enqueue host registrations while another component is
    // finishing its own mount. Publish the owner mapping before those hooks so
    // whichever mount drains the shared VM outbox can resolve every recipient.
    element._mochiModule = module;
    element._mochiInstance = instance;
    state.elements.set(String(instance), element);
    state.unmountedInstances.delete(String(instance));

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
      removeGlobalEventSubscriptions(instance, mountToken);
      if (state.elements.get(String(instance)) === element) {
        state.elements.delete(String(instance));
      }
      var cleanupError = disposeVmInstance(module, instance);
      if (cleanupError) {
        console.error("[mochi] " + component.tag_name + " rollback cleanup failed", cleanupError);
      }
      element._mochiModule = null;
      element._mochiInstance = null;
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

  function bindingSource(binding) {
    if (!binding) return null;
    if (binding.source && binding.source.file) return binding.source;
    var rowSource = binding.each_rows && binding.each_rows.span;
    return rowSource && rowSource.file ? rowSource : null;
  }

  function bindingContext(element, binding, context) {
    var component = element && element._mochiComponent || {};
    var name = component.tag_name || component.class_name || "component";
    if (component.class_name && component.class_name !== name) name += " (" + component.class_name + ")";
    var details = [name, "binding " + binding.id, "kind " + (binding.kind || "unknown")];
    if (binding.attr_name) details.push("attribute " + JSON.stringify(binding.attr_name));
    var source = bindingSource(binding);
    if (source) {
      var location = source.file;
      if (source.line) location += ":" + source.line;
      if (source.column) location += ":" + source.column;
      if (source.end_line && source.end_column) location += "-" + source.end_line + ":" + source.end_column;
      details.push("Ruby source " + location);
    }
    if (context) details.push("install context " + context);
    return details.join(", ");
  }

  function bindingTargetTypeError(node, binding) {
    var type = node && node.nodeType;
    if (["text", "text_html", "html", "attr", "prop", "cond", "each"].indexOf(binding.kind) === -1) return true;
    if (binding.kind === "text") return type !== 3;
    if (binding.kind === "attr" || binding.kind === "prop") return type !== 1;
    if (binding.kind === "html") return type !== 1 && type !== 3;
    if (binding.kind === "cond" || binding.kind === "each") return type !== 8;
    if (binding.kind === "text_html") return type !== 1 && type !== 3;
    return false;
  }

  function validateBindingPlaceholder(element, node, binding, context) {
    // Conditional and each bindings target comment anchors. Their expressions
    // describe branch/row state, not literal placeholders on the anchor.
    if (["text", "text_html", "html", "attr", "prop"].indexOf(binding.kind) === -1) return;
    if (typeof binding.template_start !== "number" ||
        typeof binding.template_end !== "number" ||
        binding.template_end <= binding.template_start) return;
    if (typeof binding.template_text !== "string") {
      throw new Error("mochi-loader: missing compiler placeholder source for " +
        bindingContext(element, binding, context));
    }

    var start = byteOffsetToIndex(binding.template_text, binding.template_start);
    var end = byteOffsetToIndex(binding.template_text, binding.template_end);
    var placeholder = binding.template_text.slice(start, end);
    if (placeholder.length < 2 || placeholder.charAt(0) !== "{" ||
        placeholder.charAt(placeholder.length - 1) !== "}") {
      throw new Error("mochi-loader: invalid compiler placeholder range for " +
        bindingContext(element, binding, context));
    }

    var targetText;
    if (binding.kind === "attr" || binding.kind === "prop") {
      targetText = binding.attr_name && node && typeof node.getAttribute === "function"
        ? node.getAttribute(binding.attr_name) : null;
    } else {
      targetText = node && typeof node.textContent === "string" ? node.textContent : null;
    }
    if (typeof targetText !== "string" || targetText.indexOf(placeholder) === -1) {
      throw new Error("mochi-loader: compiler placeholder " + JSON.stringify(placeholder) +
        " is missing from its resolved target for " + bindingContext(element, binding, context));
    }
  }

  function installBindingTarget(element, root, binding, context) {
    var path = binding.path || [];
    var node = resolveTarget(root, path);
    var description = bindingContext(element, binding, context);
    if (!node) {
      throw new Error("mochi-loader: missing binding target at path [" + path.join(", ") + "] for " + description);
    }
    if (bindingTargetTypeError(node, binding)) {
      throw new Error("mochi-loader: invalid " + binding.kind + " binding target (DOM node type " + node.nodeType + ") at path [" + path.join(", ") + "] for " + description);
    }
    validateBindingPlaceholder(element, node, binding, context);

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
      pointer_id: event && typeof event.pointerId === "number" ? event.pointerId : -1,
      pointer_type: event && typeof event.pointerType === "string" ? event.pointerType : "",
      is_primary: !!(event && event.isPrimary),
      buttons: event && typeof event.buttons === "number" ? event.buttons : 0,
      pointer_reason: pointerReason(event),
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

  function rowFragmentFor(html, context, descriptor) {
    if (!descriptor.context_tag && !descriptor.context_namespace) {
      return fragmentFor(html);
    }
    if (!context || context.nodeType !== 1) {
      // Generic root rows do not need an element-specific parser context. A
      // top-level each anchor lives under the component ShadowRoot, which is
      // a DocumentFragment rather than an element; keep context-sensitive
      // table/select/SVG rows strict and parse only this generic case normally.
      if (context && context.nodeType === 11 &&
          (!descriptor.context_tag || String(descriptor.context_tag).toLowerCase() === "body") &&
          (!descriptor.context_namespace || descriptor.context_namespace === "html")) {
        return fragmentFor(html);
      }
      throw new Error("mochi-loader: each row has no element insertion context for binding " + descriptor.id);
    }
    var expectedTag = descriptor.context_tag;
    var expectedNamespace = descriptor.context_namespace;
    var actualTag = String(context.localName || context.tagName || "").toLowerCase();
    var actualNamespace = context.namespaceURI === "http://www.w3.org/2000/svg" ? "svg" : "html";
    if ((expectedTag && String(expectedTag).toLowerCase() !== actualTag) ||
        (expectedNamespace && expectedNamespace !== actualNamespace)) {
      var location = descriptor.span && descriptor.span.source ? " at " + descriptor.span.source : "";
      throw new Error("mochi-loader: each row context mismatch" + location +
        ": expected <" + (expectedTag || "?") + "> in " + (expectedNamespace || "?") +
        ", found <" + actualTag + "> in " + actualNamespace);
    }
    var range = global.document.createRange();
    range.selectNodeContents(context);
    return range.createContextualFragment(html || "");
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
    target.innerHTML = resolveIconAssetReferences(
      displayBindingValue(value),
      state.manifest,
      state.manifestUrl
    );
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

  function buildRowEntry(descriptor, row, index, parentContext, insertionContext) {
    var fragment = rowFragmentFor(rowTemplateMarkup(descriptor), insertionContext, descriptor);
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

  function composedContainsNode(host, node) {
    var current = node;
    while (current) {
      if (current === host) return true;
      if (current.parentNode) {
        current = current.parentNode;
        continue;
      }
      var root = current.getRootNode && current.getRootNode();
      current = root && root.host ? root.host : null;
    }
    return false;
  }

  function moveRowAfter(entry, reference) {
    var parent = reference.parentNode;
    if (!parent) return;
    var active = null;
    var selection = null;
    var root = entry.start.getRootNode && entry.start.getRootNode();
    var focused = root && deepActiveElement(root);
    if (focused && rowRange(entry).some(function (node) {
      return composedContainsNode(node, focused);
    })) {
      active = focused;
      if (typeof focused.selectionStart === "number" && typeof focused.selectionEnd === "number") {
        selection = {
          start: focused.selectionStart,
          end: focused.selectionEnd,
          direction: focused.selectionDirection
        };
      }
    }
    var anchor = reference.nextSibling;
    rowRange(entry).forEach(function (node) {
      parent.insertBefore(node, anchor);
    });
    if (active && active.isConnected) {
      focusNode(active);
      if (selection && typeof active.setSelectionRange === "function") {
        try { active.setSelectionRange(selection.start, selection.end, selection.direction || "none"); } catch (_) { }
      }
    }
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
      if (!entry) entry = buildRowEntry(descriptor, item.row, item.index, parentContext, parent);
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
    if (state.styleTextCache.has(id)) return state.styleTextCache.get(id);
    var resources = state.manifest && state.manifest.resources;
    var resource = resources && resources[id];
    if (resource && resource.kind === "style" && typeof resource.text === "string") {
      state.styleTextCache.set(id, resource.text);
      return resource.text;
    }
    throw new Error(
      (tag || "component") + " references unloaded style resource " + id
    );
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

  // Immutable per-component compilation data. Two instances share the parsed
  // template, flattened bindings, and event names; each keeps its own VM
  // instance and binding targets.
  function componentRuntime(component) {
    var key = component.tag_name || component.descriptor || component.class_name;
    var cached = state.componentRuntimeCache.get(key);
    if (cached) return cached;

    var template = global.document.createElement("template");
    template.innerHTML = component.html_template || "";
    var bindings = Array.isArray(component.bindings) ? component.bindings : [];
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

    var runtime = {
      template: template,
      bindings: bindings,
      allBindings: allBindings,
      eventNames: eventNames
    };
    state.componentRuntimeCache.set(key, runtime);
    return runtime;
  }

  function defineComponent(entry, manifestUrl) {
    var tag = entry.tag_name;
    if (!tag || state.tags.has(tag) || global.customElements.get(tag)) return;

    var Element = class extends global.HTMLElement {
      constructor() {
        super();
        this.bindingTargets = {};
        this.bindingData = {};
        this.bindingValues = {};
        this.refs = this.bindingTargets;
        // The entry manifest only carries identity. The descriptor replaces
        // this object after the first-use fetch; until then errors can still
        // name the tag and class.
        this._mochiComponent = entry;
        this._mochiRuntime = null;
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
        this._mochiRuntime = null;
        this._mochiComponent = entry;
        focusStacks.delete(this);
        this.refs = this.bindingTargets;
        this._mochiMountToken = ++state.nextMountToken;
        var mountToken = this._mochiMountToken;
        var element = this;

        this._mochiReady = loadComponentDescriptor(entry, state.manifest, manifestUrl)
          .then(function (loaded) {
            // The descriptor download can outlive the connection. Settle the
            // cancelled mount before touching styles, the shadow tree, or the
            // VM so a detached element never becomes a ghost instance.
            if (element._mochiMountToken !== mountToken ||
                element._mochiDisconnected || !element.isConnected) {
              element._settleCancelledMount(mountToken);
              return { cancelled: true, mountToken: mountToken };
            }

            element._mochiComponent = loaded;
            var runtime = componentRuntime(loaded);
            element._mochiRuntime = runtime;
            runtime.allBindings.forEach(function (binding) {
              element.bindingData[binding.id] = binding;
            });

            try {
              installComponentStyles(root, loaded);
            } catch (error) {
              if (error && typeof error === "object") error.mochiPhase = "style";
              throw error;
            }

            var fragment = runtime.template.content.cloneNode(true);
            try {
              element._resolveBindings(fragment);
              root.appendChild(fragment);
            } catch (error) {
              if (error && typeof error === "object") error.mochiPhase = "binding";
              throw error;
            }
            // The retained shadow root outlives every mount, so one delegated
            // listener per event serves all lifecycles of this element.
            if (!element._mochiEventsAttached) {
              element._attachEvents(root);
              element._mochiEventsAttached = true;
            }

            return mountInstance(loaded, state.manifest, manifestUrl, element, mountToken);
          })
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
              var phase = error && error.mochiPhase ? error.mochiPhase : "mount";
              var reported = reportError(
                element, phase, methodFromError(error, "initialize"),
                error, element._mochiModule
              );
              // A failed transaction must not leave generated placeholders or
              // partially installed compiler targets observable in the host.
              while (root.firstChild) root.removeChild(root.firstChild);
              element.bindingTargets = {};
              element.bindingValues = {};
              element.bindingData = {};
              element.refs = element.bindingTargets;
              throw reported;
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
            discardHostOutboxes(module);
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
              discardHostOutboxes(module);
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
            discardHostOutboxes(module);
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
        if (this._mochiPointerObserver) {
          this._mochiPointerObserver.disconnect();
          this._mochiPointerObserver = null;
        }
        this._mochiModule = null;
        this._mochiInstance = null;
        this._mochiAttributeValues = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.bindingData = {};
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
        if (this._mochiPointerObserver) {
          this._mochiPointerObserver.disconnect();
          this._mochiPointerObserver = null;
        }

        var key = String(instance);
        state.unmountedInstances.add(key);
        discardPointerMoves(this);
        cancelOwnerFetches(key);
        cancelOwnerPointerCaptures(key, mountToken);
        state.timers.forEach(function (record, timerId) {
          if (record.instance === key) clearTimerEntry(timerId);
        });
        state.pendingHostRequests.forEach(function (request, requestKey) {
          if (String(request.instance) === key) state.pendingHostRequests.delete(requestKey);
        });
        if (state.elements.get(key) === this) state.elements.delete(key);
        state.routeSubscribers.delete(key);
        removeGlobalEventSubscriptions(key, mountToken);
        state.storageSubscribers.forEach(function (subscribers, storageKey) {
          subscribers.delete(key);
          if (subscribers.size === 0) state.storageSubscribers.delete(storageKey);
        });

        try {
          if (hasMethod(module, instance, "unmounted")) {
            var symbol = intern(module, "unmounted");
            if (module._mochi_dispatch_event(instance, symbol) !== 1) {
              throw new Error("mochi-loader: unmounted dispatch failed for " + tag + ": " + lastError(module));
            }
          }
        } catch (error) {
          discardHostOutboxes(module);
          reportError(this, "unmount", "unmounted", error, module);
        }

        // Failed hooks discard their batch above. Successful hooks may deliver
        // cleanup commands while the owner is still marked unmounted.
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
        // Tombstones protect the synchronous unmounted-hook/outbox drain. All
        // owner work is canceled and drained before this point, so retaining
        // one per historical instance would grow without bound.
        state.unmountedInstances.delete(key);

        this._mochiModule = null;
        this._mochiInstance = null;
        this._mochiAttributeValues = null;
        this.bindingTargets = {};
        this.bindingValues = {};
        this.bindingData = {};
        focusStacks.delete(this);
        this.refs = this.bindingTargets;
      }

      _resolveBindings(root) {
        var runtime = this._mochiRuntime;
        if (!runtime) return;
        var bindings = runtime.bindings;
        for (var i = 0; i < bindings.length; i++) {
          installBindingTarget(this, root, bindings[i], tag);
        }
      }

      _attachEvents(root) {
        var element = this;
        var eventNames = this._mochiRuntime ? this._mochiRuntime.eventNames : [];
        eventNames.forEach(function (eventName) {
          root.addEventListener(eventName, function (event) {
            var target = eventTarget(event, root, eventName);
            if (target) element._dispatch(target, event);
          });
        });
        var component = this._mochiComponent || {};
        if (Array.isArray(component.capabilities) && component.capabilities.indexOf("pointer") !== -1 &&
            typeof global.MutationObserver === "function") {
          if (this._mochiPointerObserver) this._mochiPointerObserver.disconnect();
          this._mochiPointerObserver = new global.MutationObserver(function () {
            discardPointerMoves(element, element.shadowRoot);
            var adapter = state.hostAdapters.get("pointer");
            if (!adapter || typeof adapter.reconcileOwner !== "function" ||
                element._mochiUnmounted || element._mochiInstance === null ||
                element._mochiInstance === undefined) return;
            try {
              adapter.reconcileOwner(
                String(element._mochiInstance), element._mochiMountToken, element.shadowRoot
              );
            } catch (error) {
              reportError(element, "pointer", "reconcile", error, element._mochiModule);
            }
          });
          this._mochiPointerObserver.observe(root, { childList: true, subtree: true });
        }
      }

      _dispatch(target, event, fromPointerMoveQueue) {
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

        if (event && typeof event.pointerId === "number") {
          if (event.type === "pointermove" && !fromPointerMoveQueue) {
            queuePointerMove(this, target, event);
            return;
          }
          if (event.type === "pointerup" || event.type === "pointercancel" ||
              event.type === "lostpointercapture") {
            flushPointerMove(this, event.pointerId);
          }
        }

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
        var dragEvent = event && (event.type === "dragstart" || event.type === "dragover" || event.type === "drop");
        var mountedNow = this._mochiModule && this._mochiInstance !== null &&
          this._mochiInstance !== undefined && this._mochiMountState === "mounted"
          ? { module: this._mochiModule, instance: this._mochiInstance, mountToken: mountToken }
          : null;
        if (dragEvent && mountedNow && componentCapabilities(this._mochiComponent).indexOf("drag") !== -1) {
          var previousDragDispatch = state.activeDragDispatch;
          var dragAdapter = state.hostAdapters.get("drag");
          if (!dragAdapter || typeof dragAdapter.snapshot !== "function") {
            reportError(element, "event", method, new Error("mochi-drag: drag adapter is unavailable"));
            return;
          }
          try {
            if (event.type === "drop") Object.assign(payload, dragAdapter.snapshot(event, dragAdapter.limits));
            var sourceInfo = event.type === "dragstart" ? eventNodeInfo(event.target) : payload.drag_source || null;
            state.activeDragDispatch = {
              element: element,
              target: target,
              event: event,
              mountToken: mountToken,
              source: sourceInfo
            };
            var syncSymbol = intern(mountedNow.module, method);
            var syncDispatched;
            if (method.indexOf("__mochi_each_") === 0) {
              if (eachContexts.length === 0) throw new Error("mochi-loader: list row event " + method + " has no row context");
              var syncRowArgs = [];
              eachContexts.forEach(function (context) {
                syncRowArgs.push(context.item);
                syncRowArgs.push(context.index);
              });
              syncRowArgs.push(payload);
              syncDispatched = dispatchEventArgs(mountedNow.module, mountedNow.instance, syncSymbol, syncRowArgs);
            } else if (descriptors.length > 0) {
              var syncArgs = descriptors.map(function (descriptor) {
                return eventArgumentValue(element, descriptor, target, payload);
              });
              syncDispatched = dispatchEventArgs(mountedNow.module, mountedNow.instance, syncSymbol, syncArgs);
            } else if (requiredArgumentCount(mountedNow.module, mountedNow.instance, syncSymbol) === 1) {
              syncDispatched = dispatchEventArgs(mountedNow.module, mountedNow.instance, syncSymbol, [payload]);
            } else {
              syncDispatched = mountedNow.module._mochi_dispatch_event(mountedNow.instance, syncSymbol) === 1;
            }
            if (!syncDispatched) throw new Error("mochi-loader: event dispatch failed for " + method + ": " + lastError(mountedNow.module));
            applyPatches(element, mountedNow.module);
            drainEmits(mountedNow.module);
            drainFetches(mountedNow.module);
            state.activeDragDispatch = previousDragDispatch;
          } catch (error) {
            state.activeDragDispatch = previousDragDispatch;
            discardHostOutboxes(mountedNow.module);
            reportError(element, "event", method, error, mountedNow.module);
          }
          return;
        }
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
          var previousPointerDispatch = state.activePointerDispatch;
          state.activePointerDispatch = event && typeof event.pointerId === "number"
            ? { element: element, target: target, event: event, mountToken: mountToken }
            : null;
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
          state.activePointerDispatch = previousPointerDispatch;
        }).catch(function (error) {
          state.activePointerDispatch = null;
          discardHostOutboxes(element._mochiModule);
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

        var previousActionContext = state.activeActionContext;
        try {
          if (!actionSupported(module, this, action)) return;

          var symbol = intern(module, action);
          state.activeActionContext = { element: this, method: action };
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
          state.activeActionContext = previousActionContext;
        } catch (error) {
          state.activeActionContext = previousActionContext;
          discardHostOutboxes(module);
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
    var profile = manifest.capacity_profile;
    if (!profile || typeof profile !== "object" || Array.isArray(profile) ||
        profile.schema_version !== 1 || typeof profile.fingerprint !== "string" ||
        !/^[a-f0-9]{64}$/.test(profile.fingerprint) ||
        !Number.isSafeInteger(profile.memory_bytes) || profile.memory_bytes <= 0 ||
        !profile.capacities || typeof profile.capacities !== "object" || Array.isArray(profile.capacities)) {
      throw new Error("mochi-loader: manifest " + manifestUrl + " has an invalid capacity profile");
    }
    Object.keys(CAPABILITY_LIMIT_KEYS).forEach(function (name) {
      Object.keys(CAPABILITY_LIMIT_KEYS[name]).forEach(function (limitName) {
        var capacityName = CAPABILITY_LIMIT_KEYS[name][limitName];
        var value = profile.capacities[capacityName];
        if (!Number.isSafeInteger(value) || value <= 0 || value > 2147483647) {
          throw new Error("mochi-loader: capacity profile requires positive 32-bit " + capacityName);
        }
      });
    });
    GLOBAL_EVENT_QUEUE_CAPACITIES.forEach(function (capacityName) {
      var value = profile.capacities[capacityName];
      if (!Number.isSafeInteger(value) || value <= 0) {
        throw new Error("mochi-loader: capacity profile is missing positive " + capacityName);
      }
    });
    manifest.components.forEach(function (entry, index) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        throw new Error("mochi-loader: manifest component index entry " + index +
          " must be an object in " + manifestUrl);
      }
      if (typeof entry.tag_name !== "string" || entry.tag_name.length === 0) {
        throw new Error("mochi-loader: manifest component index entry " + index +
          " has no tag name in " + manifestUrl);
      }
      if (typeof entry.descriptor !== "string" || entry.descriptor.length === 0) {
        throw new Error("mochi-loader: manifest component index entry '" + entry.tag_name +
          "' has no descriptor location in " + manifestUrl);
      }
    });
    if (!manifest.packages || typeof manifest.packages !== "object" || Array.isArray(manifest.packages)) {
      throw new Error("mochi-loader: manifest " + manifestUrl + " has no package descriptors");
    }
    if (manifest.format_host !== undefined && !localAdapterLocation(manifest.format_host)) {
      throw new Error("mochi-loader: manifest " + manifestUrl +
        " has an invalid formatting adapter location");
    }
    if (manifest.capabilities !== undefined) {
      if (!manifest.capabilities || typeof manifest.capabilities !== "object" ||
          Array.isArray(manifest.capabilities)) {
        throw new Error("mochi-loader: manifest " + manifestUrl +
          " has an invalid capabilities table");
      }
      Object.keys(manifest.capabilities).sort().forEach(function (name) {
        var capability = manifest.capabilities[name];
        if (!capability || typeof capability !== "object" || Array.isArray(capability)) {
          throw new Error("mochi-loader: capability '" + name +
            "' must be an object in " + manifestUrl);
        }
        if (!Number.isInteger(capability.version) || capability.version <= 0) {
          throw new Error("mochi-loader: capability '" + name +
            "' has no supported version in " + manifestUrl);
        }
        if (capability.host !== undefined && capability.host !== null &&
            (!localAdapterLocation(capability.host))) {
          throw new Error("mochi-loader: capability '" + name +
            "' has an invalid adapter location in " + manifestUrl);
        }
        var limitSchema = CAPABILITY_LIMIT_KEYS[name];
        if (limitSchema && capability.host) {
          var limits = capability.limits;
          if (!limits || typeof limits !== "object" || Array.isArray(limits)) {
            throw new Error("mochi-loader: capability '" + name + "' has no host limits in " + manifestUrl);
          }
          Object.keys(limitSchema).forEach(function (limitName) {
            var value = limits[limitName];
            var capacityName = limitSchema[limitName];
            if (!Number.isSafeInteger(value) || value <= 0 ||
                value !== profile.capacities[capacityName]) {
              throw new Error("mochi-loader: capability '" + name + "' limit '" + limitName +
                "' does not match compiled capacity '" + capacityName + "' in " + manifestUrl);
            }
          });
          if (Object.keys(limits).length !== Object.keys(limitSchema).length) {
            throw new Error("mochi-loader: capability '" + name + "' has unknown host limits in " + manifestUrl);
          }
          var entries = name === "formatting" ? limits.cache_entries : limits.pending_requests;
          if (entries > 65535) {
            throw hostAdapterError(name, capability.host, null, "host limit exceeds the 16-bit table capacity");
          }
          if (name === "network") {
            if (limits.envelope_bytes < 1024 || limits.response_bytes * 12 + 256 > limits.envelope_bytes) {
              throw hostAdapterError(name, capability.host, null,
                "response capacity exceeds the fetch envelope after JSON expansion and metadata");
            }
            if (limits.pending_requests * limits.response_bytes > limits.response_buffer_bytes) {
              throw hostAdapterError(name, capability.host, null,
                "concurrent responses exceed the response buffer capacity");
            }
          }
        }
        if (capability.operations !== undefined) {
          if (!capability.operations || typeof capability.operations !== "object" ||
              Array.isArray(capability.operations)) {
            throw new Error("mochi-loader: capability '" + name +
              "' has an invalid operation table in " + manifestUrl);
          }
          Object.keys(capability.operations).forEach(function (operation) {
            var mode = capability.operations[operation];
            if (mode !== "sync" && mode !== "async") {
              throw new Error("mochi-loader: capability '" + name + "' operation '" +
                operation + "' must be sync or async in " + manifestUrl);
            }
          });
        }
      });
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
    var storageSubscriberCount = 0;
    var storageSubscriptionKeys = 0;
    state.storageSubscribers.forEach(function (subscribers) {
      storageSubscriptionKeys += 1;
      storageSubscriberCount += subscribers.size;
    });
    var globalEventSubscriberCount = 0;
    var globalEventSubscriptionKeys = 0;
    state.globalEventSubscribers.forEach(function (subscribers) {
      globalEventSubscriptionKeys += 1;
      globalEventSubscriberCount += subscribers.size;
    });
    return {
      capacityProfile: module && typeof module._mochi_capacity_profile === "function" &&
        typeof module.UTF8ToString === "function"
        ? JSON.parse(module.UTF8ToString(module._mochi_capacity_profile())) : null,
      bindings: module && typeof module._mochi_binding_count === "function"
        ? Number(module._mochi_binding_count()) : -1,
      components: module && typeof module._mochi_component_count === "function"
        ? Number(module._mochi_component_count()) : -1,
      elements: state.elements.size,
      timers: state.timers.size,
      pendingFetches: state.pendingFetches.length,
      activeFetches: state.activeFetches.size,
      pendingHostRequests: state.pendingHostRequests.size,
      pendingPointerMoves: state.pointerMoves.size,
      routeSubscribers: state.routeSubscribers.size,
      storageSubscribers: storageSubscriberCount,
      storageSubscriptionKeys: storageSubscriptionKeys,
      globalEventSubscribers: globalEventSubscriberCount,
      globalEventSubscriptionKeys: globalEventSubscriptionKeys,
      globalEventQueueEntries: state.globalEventQueue.length,
      globalEventQueueBytes: state.globalEventQueueBytes,
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
      var manifestUrl = absoluteUrl(manifestPath, script.src || global.document.baseURI);
      var start = function () {
        boot(manifestUrl).catch(function (error) {
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
