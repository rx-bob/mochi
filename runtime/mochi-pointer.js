// Optional pointer capture adapter. The loader supplies a mount-owned target;
// Ruby never receives a DOM object or a direct browser bridge.
(function (global) {
  "use strict";

  var captures = new Map();

  function fail(message) {
    throw new Error("pointer: " + message);
  }

  function integerPointerId(value) {
    return Number.isSafeInteger(value) && value >= 0;
  }

  function forget(pointerId, record) {
    if (captures.get(pointerId) !== record) return;
    captures.delete(pointerId);
    if (record.target && record.onLost) {
      record.target.removeEventListener("lostpointercapture", record.onLost);
    }
  }

  function capture(target, pointerId, owner, mountToken, event) {
    if (!integerPointerId(pointerId)) fail("pointer_id must be a non-negative Integer");
    if (!target || target.nodeType !== 1 || target.isConnected !== true) {
      fail("capture target is stale or disconnected");
    }
    if (!event || event.pointerId !== pointerId ||
        typeof event.buttons !== "number" || event.buttons === 0) {
      fail("capture requires the matching active pointer event");
    }
    if (typeof target.setPointerCapture !== "function" ||
        typeof target.hasPointerCapture !== "function") {
      fail("pointer capture is unavailable on this target");
    }
    var existing = captures.get(pointerId);
    if (existing && (existing.owner !== owner || existing.mountToken !== mountToken)) {
      fail("pointer " + pointerId + " is captured by another live component");
    }
    try {
      target.setPointerCapture(pointerId);
      if (!target.hasPointerCapture(pointerId)) {
        fail("browser did not accept capture for pointer " + pointerId);
      }
    } catch (error) {
      if (error && error.message && error.message.indexOf("pointer:") === 0) throw error;
      fail("cannot capture pointer " + pointerId + ": " +
        (error && error.message ? error.message : String(error)));
    }
    if (existing) forget(pointerId, existing);
    var record = {
      target: target,
      owner: owner,
      mountToken: mountToken,
      captured: true,
      onLost: null,
    };
    record.onLost = function (lostEvent) {
      if (!lostEvent || lostEvent.pointerId === pointerId) {
        record.captured = false;
        // Native pointer-up may dispatch lostpointercapture before Mochi's
        // queued Ruby pointer-up handler runs. Keep ownership through this
        // microtask so an explicit Ruby release remains valid.
        var cleanup = function () { forget(pointerId, record); };
        if (typeof global.queueMicrotask === "function") global.queueMicrotask(cleanup);
        else Promise.resolve().then(cleanup);
      }
    };
    target.addEventListener("lostpointercapture", record.onLost);
    captures.set(pointerId, record);
    return true;
  }

  function release(pointerId, owner, mountToken, expectedTarget) {
    if (!integerPointerId(pointerId)) fail("pointer_id must be a non-negative Integer");
    var record = captures.get(pointerId);
    if (!record || record.owner !== owner || record.mountToken !== mountToken) {
      fail("no live capture owned by this component for pointer " + pointerId);
    }
    if (expectedTarget && expectedTarget !== record.target) {
      fail("capture target is not owned by this component mount");
    }
    try {
      if (record.captured && record.target.hasPointerCapture(pointerId)) {
        record.target.releasePointerCapture(pointerId);
      }
    } catch (error) {
      fail("cannot release pointer " + pointerId + ": " +
        (error && error.message ? error.message : String(error)));
    } finally {
      forget(pointerId, record);
    }
    return true;
  }

  function disposeOwner(owner, mountToken) {
    Array.from(captures.entries()).forEach(function (entry) {
      var pointerId = entry[0];
      var record = entry[1];
      if (record.owner !== owner || record.mountToken !== mountToken) return;
      try {
        if (record.captured && record.target.hasPointerCapture(pointerId)) {
          record.target.releasePointerCapture(pointerId);
        }
      } catch (_) {
        // Disposal must remove our ownership record even if the browser has
        // already ended the pointer lifecycle.
      }
      forget(pointerId, record);
    });
  }

  var host = {
    name: "pointer",
    version: 1,
    sync: { capture: capture, release: release },
    disposeOwner: disposeOwner,
    debugCaptureCount: function () { return captures.size; },
  };
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) module.exports = host;
})(typeof globalThis !== "undefined" ? globalThis : window);
