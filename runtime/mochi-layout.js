// Optional, mount-owned static-ref geometry. Read every dirty target before
// invoking callbacks, so Ruby writes cannot interleave this frame's reads.
(function (global) {
  "use strict";
  var records = new Set();
  var frame = null;

  function reference(argsJson) {
    var args = JSON.parse(argsJson);
    if (!Array.isArray(args) || args.length !== 1 || typeof args[0] !== "string" || !args[0]) {
      throw new Error("layout: expected one nonempty static ref name");
    }
    return args[0];
  }
  function live(record) {
    return record.active && record.context.isLive() && record.target.isConnected &&
      record.context.resolveRef(record.reference) === record.target;
  }
  function stop(record) {
    if (!record.active) return;
    record.active = false;
    records.delete(record);
    if (record.observer) record.observer.disconnect();
    record.context.cancel();
    // Settle the initial promise after cancellation; the loader has already
    // forgotten this request and will not publish a cancellation result.
    if (record.resolve) record.resolve(null);
    record.resolve = record.reject = null;
    if (!Array.from(records).some(function (item) { return item.dirty; }) && frame !== null) {
      global.cancelAnimationFrame(frame);
      frame = null;
    }
  }
  function geometry(target) {
    var rect = target.getBoundingClientRect();
    var result = {};
    ["x", "y", "width", "height", "top", "right", "bottom", "left"].forEach(function (key) {
      if (!Number.isFinite(rect[key])) throw new Error("layout: non-finite geometry");
      result[key] = rect[key];
    });
    return result;
  }
  function flush() {
    frame = null;
    var deliveries = [];
    var readings = new Map();
    records.forEach(function (record) {
      if (!live(record)) { stop(record); return; }
      if (!record.dirty) return;
      record.dirty = false;
      try {
        if (!readings.has(record.target)) readings.set(record.target, geometry(record.target));
        deliveries.push({ record: record, value: readings.get(record.target) });
      }
      catch (error) {
        if (record.reject) record.reject(error);
        // Leave the initial request for its rejection handler to consume.
        record.resolve = record.reject = null;
        record.active = false;
        records.delete(record);
        if (record.observer) record.observer.disconnect();
      }
    });
    deliveries.forEach(function (delivery) {
      var record = delivery.record;
      if (!live(record)) { stop(record); return; }
      if (record.observer && !record.resolve && record.width === delivery.value.width && record.height === delivery.value.height) return;
      record.width = delivery.value.width;
      record.height = delivery.value.height;
      if (!record.observer) {
        record.active = false;
        records.delete(record);
      }
      if (record.resolve) {
        var resolve = record.resolve;
        record.resolve = record.reject = null;
        // Consume the initial request in this delivery phase, keeping ref
        // identity and cancellation checks adjacent to the Ruby callback.
        record.context.complete(delivery.value);
        resolve(delivery.value);
      } else {
        record.context.notify(delivery.value);
      }
    });
  }
  function schedule(record) {
    if (!record.active) return;
    record.dirty = true;
    if (frame === null) frame = global.requestAnimationFrame(flush);
  }
  function cancelOwned(context, ref) {
    records.forEach(function (record) {
      if (record.context.owner === context.owner && record.context.mountToken === context.mountToken &&
          (ref === undefined || record.reference === ref)) stop(record);
    });
  }
  function start(argsJson, limits, context, observe) {
    var ref = reference(argsJson);
    var target = context.resolveRef(ref);
    if (!context.isLive() || !target || !target.isConnected) throw new Error("layout: missing or disconnected static ref '" + ref + "'");
    if (observe && typeof global.ResizeObserver !== "function") throw new Error("layout: ResizeObserver is unavailable");
    if (!limits || !Number.isSafeInteger(limits.requests) || limits.requests < 1) throw new Error("layout: missing request capacity");
    if (observe) cancelOwned(context, ref);
    if (records.size >= limits.requests) throw new Error("layout: request capacity exhausted (capacity " + limits.requests + ")");
    return new Promise(function (resolve, reject) {
      var record = { reference: ref, target: target, context: context, active: true,
        dirty: false, resolve: resolve, reject: reject, observer: null };
      records.add(record);
      try {
        if (observe) {
          record.observer = new global.ResizeObserver(function () { schedule(record); });
          record.observer.observe(target, { box: "border-box" });
        }
        schedule(record);
      } catch (error) {
        record.active = false;
        records.delete(record);
        if (record.observer) record.observer.disconnect();
        reject(error);
      }
    });
  }
  var adapter = {
    name: "layout", version: 1,
    async: {
      measure: function (args, limits, context) { return start(args, limits, context, false); },
      observe: function (args, limits, context) { return start(args, limits, context, true); },
      cancel: function (args, _limits, context) { cancelOwned(context, reference(args)); return true; }
    },
    disposeOwner: function (owner, mountToken) { cancelOwned({ owner: owner, mountToken: mountToken }); },
    reconcileOwner: function (owner, mountToken) {
      records.forEach(function (record) {
        if (record.context.owner === owner && record.context.mountToken === mountToken && !live(record)) stop(record);
      });
    }
  };
  if (global.MochiHostAdapter) global.MochiHostAdapter.register(adapter);
  if (typeof module === "object" && module.exports) module.exports = adapter;
})(typeof globalThis !== "undefined" ? globalThis : window);
