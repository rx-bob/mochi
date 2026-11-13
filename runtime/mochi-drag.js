// Optional native drag transfer adapter. Browser-owned DataTransfer objects
// remain inside the event window; Ruby sees only bounded normalized values.
(function (global) {
  "use strict";

  var INTERNAL_TYPE = "application/vnd.mochi.value+json";
  var MAX_DEPTH = 32;
  var MAX_ITEMS = 4096;

  function fail(message) {
    throw new Error("drag: " + message);
  }

  function bytes(text) {
    return typeof TextEncoder === "function"
      ? new TextEncoder().encode(text).length
      : unescape(encodeURIComponent(text)).length;
  }

  function validateValue(value, depth, count) {
    if (depth > MAX_DEPTH) fail("payload exceeds nesting limit");
    count.value += 1;
    if (count.value > MAX_ITEMS) fail("payload exceeds item limit");
    if (value === null || typeof value === "string" || typeof value === "boolean") return;
    if (typeof value === "number") {
      if (!Number.isFinite(value)) fail("payload contains a non-finite number");
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(function (item) { validateValue(item, depth + 1, count); });
      return;
    }
    if (value && typeof value === "object") {
      var keys = Object.keys(value);
      keys.forEach(function (key) {
        if (key === "__proto__" || key === "constructor" || key === "prototype") {
          fail("payload contains a forbidden object key");
        }
        validateValue(value[key], depth + 1, count);
      });
      return;
    }
    fail("payload contains an unsupported value");
  }

  function setData(context, value, limits) {
    if (!context || !context.event || context.event.type !== "dragstart" ||
        !context.event.dataTransfer) fail("set_data is only valid during dragstart");
    validateValue(value, 0, { value: 0 });
    var envelope = JSON.stringify({
      version: 1,
      value: value,
      source: context.source || null
    });
    if (bytes(envelope) > limits.payload_bytes) fail("payload exceeds configured byte limit");
    context.event.dataTransfer.setData(INTERNAL_TYPE, envelope);
    return true;
  }

  function setText(context, value, limits) {
    if (!context || !context.event || context.event.type !== "dragstart" ||
        !context.event.dataTransfer) fail("set_text is only valid during dragstart");
    if (typeof value !== "string") fail("set_text expects a String");
    if (bytes(value) > limits.payload_bytes) fail("text exceeds configured byte limit");
    context.event.dataTransfer.setData("text/plain", value);
    return true;
  }

  function accept(context, type, effect) {
    if (!context || !context.event || context.event.type !== "dragover" ||
        !context.event.dataTransfer) fail("accept is only valid during dragover");
    if (["copy", "move", "link"].indexOf(effect) === -1) fail("unsupported drop effect");
    var types = Array.prototype.slice.call(context.event.dataTransfer.types || []);
    if (types.indexOf(type) === -1) return false;
    context.event.preventDefault();
    context.event.dataTransfer.dropEffect = effect;
    return true;
  }

  function snapshot(event, limits) {
    if (!event || event.type !== "drop" || !event.dataTransfer) return {};
    var transfer = event.dataTransfer;
    var result = {
      drag_types: Array.prototype.slice.call(transfer.types || []).slice(0, 32),
      drag_effect: typeof transfer.dropEffect === "string" ? transfer.dropEffect : "none",
      drag_value: null,
      drag_text: "",
      drag_source: null
    };
    if (result.drag_types.indexOf(INTERNAL_TYPE) !== -1) {
      var raw = transfer.getData(INTERNAL_TYPE);
      if (bytes(raw) > limits.payload_bytes) fail("received payload exceeds configured byte limit");
      var envelope;
      try { envelope = JSON.parse(raw); } catch (_) { fail("received typed payload is malformed"); }
      if (!envelope || envelope.version !== 1 || !Object.prototype.hasOwnProperty.call(envelope, "value")) {
        fail("received typed payload has an unsupported version");
      }
      validateValue(envelope.value, 0, { value: 0 });
      result.drag_value = envelope.value;
      result.drag_source = envelope.source && typeof envelope.source === "object"
        ? envelope.source
        : null;
    }
    if (result.drag_types.indexOf("text/plain") !== -1) {
      result.drag_text = transfer.getData("text/plain");
      if (bytes(result.drag_text) > limits.payload_bytes) fail("received text exceeds configured byte limit");
    }
    return result;
  }

  var host = {
    name: "drag",
    version: 1,
    sync: { set_data: setData, set_text: setText, accept: accept },
    snapshot: snapshot,
    internalType: INTERNAL_TYPE
  };
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) module.exports = host;
})(typeof globalThis !== "undefined" ? globalThis : window);
