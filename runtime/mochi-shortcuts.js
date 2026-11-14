// Optional mount-owned keyboard scopes. No listener exists without a live
// registration; a successful registration never invokes its action callback.
(function (global) {
  "use strict";
  var records = new Map();
  var listening = false;
  var sequence = 0;
  var flags = ["ctrl", "alt", "meta", "shift", "prevent", "allow_editable", "repeat"];
  function owner(context) { return context.owner + ":" + context.mountToken; }
  function id(context, token) { return owner(context) + ":" + token; }
  function key(value) { return value.length === 1 ? value.toLowerCase() : value; }
  function remove(record) {
    records.delete(id(record.context, record.token));
    record.context.cancel();
    if (!records.size && listening) {
      global.document.removeEventListener("keydown", handle, true);
      listening = false;
    }
  }
  function active(record) {
    if (!record.context.isLive()) { remove(record); return false; }
    var target = record.options.active_ref ? record.context.resolveRef(record.options.active_ref) : record.context;
    if (!target || (record.options.active_ref && !target.isConnected)) { record.target = null; return false; }
    if (target !== record.target) { record.target = target; record.order = ++sequence; }
    return true;
  }
  function editable(path) {
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (!node || node.nodeType !== 1) continue;
      var tag = String(node.tagName).toLowerCase();
      if (tag === "input" || tag === "textarea" || tag === "select") return true;
      if (node.isContentEditable) return true;
      if (node.hasAttribute("contenteditable")) {
        // An explicit false island ends contenteditable inheritance.
        return node.getAttribute("contenteditable").toLowerCase() !== "false";
      }
    }
    return false;
  }
  function handle(event) {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229 || typeof event.key !== "string") return;
    var activeOwner = null, activeOrder = -1, eligible = [];
    records.forEach(function (record) {
      if (!active(record)) return;
      eligible.push(record);
      if (record.options.scope === "application" && record.order > activeOrder) {
        activeOwner = owner(record.context); activeOrder = record.order;
      }
    });
    var path = event.composedPath();
    var inEditor = editable(path);
    var winner = null, distance = Infinity;
    eligible.forEach(function (record) {
      var options = record.options;
      if (activeOwner && owner(record.context) !== activeOwner) return;
      var index = options.active_ref ? path.indexOf(record.target) : record.context.eventScopeIndex(path);
      if (options.scope === "component" && index < 0) return;
      if (record.key !== key(event.key) || (event.repeat && !options.repeat) || (inEditor && !options.allow_editable)) return;
      if (!!event.ctrlKey !== options.ctrl || !!event.altKey !== options.alt ||
          !!event.metaKey !== options.meta || !!event.shiftKey !== options.shift) return;
      var rank = options.scope === "application" ? -1 : index;
      if (!winner || rank < distance || (rank === distance && record.order > winner.order)) {
        winner = record; distance = rank;
      }
    });
    if (!winner || !winner.context.isLive()) return;
    if (winner.options.prevent) event.preventDefault();
    winner.context.notify({ token: winner.token, key: event.key, code: event.code || "",
      ctrl_key: !!event.ctrlKey, alt_key: !!event.altKey, meta_key: !!event.metaKey,
      shift_key: !!event.shiftKey, repeat: !!event.repeat });
  }
  function register(argsJson, limits, context) {
    var args = JSON.parse(argsJson);
    if (!Array.isArray(args) || args.length !== 2 || typeof args[0] !== "string" || !args[0] ||
        !args[1] || typeof args[1] !== "object" || Array.isArray(args[1])) throw new Error("shortcuts: expected key and options Hash");
    if (!context.request.callback) throw new Error("shortcuts: callback must not be empty");
    var options = { scope: "component", active_ref: null, ctrl: false, alt: false, meta: false, shift: false,
      prevent: false, allow_editable: false, repeat: false };
    Object.keys(args[1]).forEach(function (name) {
      if (name === "scope") {
        if (!["component", "application"].includes(args[1][name])) throw new Error("shortcuts: scope must be component or application");
      } else if (name === "active_ref") {
        if (typeof args[1][name] !== "string" || !args[1][name]) throw new Error("shortcuts: active_ref must name a static ref");
      } else if (!flags.includes(name) || typeof args[1][name] !== "boolean") {
        throw new Error("shortcuts: unknown option or non-Boolean value '" + name + "'");
      }
      options[name] = args[1][name];
    });
    if (!context.isLive()) throw new Error("shortcuts: owner is not live");
    records.forEach(function (record) { if (!record.context.isLive()) remove(record); });
    if (!limits || !Number.isSafeInteger(limits.registrations) || limits.registrations < 1) throw new Error("shortcuts: missing registration capacity");
    if (records.size >= limits.registrations) throw new Error("shortcuts: registration capacity exhausted (capacity " + limits.registrations + ")");
    var token = Number(context.request.id);
    if (!Number.isSafeInteger(token) || token < 1) throw new Error("shortcuts: invalid cleanup token");
    if (!listening) {
      global.document.addEventListener("keydown", handle, true);
      listening = true;
    }
    var record = { token: token, context: context, key: key(args[0]), options: options, target: null, order: 0 };
    records.set(id(context, token), record);
    active(record);
    context.cancel();
    return token;
  }
  var adapter = {
    name: "shortcuts", version: 1,
    async: {
      register: register,
      cancel: function (argsJson, _limits, context) {
        var args = JSON.parse(argsJson);
        if (!Array.isArray(args) || args.length !== 1 || !Number.isSafeInteger(args[0]) || args[0] < 1) throw new Error("shortcuts: expected cleanup token");
        var record = records.get(id(context, args[0]));
        if (record) remove(record);
        return true;
      }
    },
    reconcileOwner: function (instance, mountToken) {
      records.forEach(function (record) {
        if (record.context.owner === instance && record.context.mountToken === mountToken) active(record);
      });
    },
    disposeOwner: function (instance, mountToken) {
      records.forEach(function (record) {
        if (record.context.owner === instance && record.context.mountToken === mountToken) remove(record);
      });
    }
  };
  if (global.MochiHostAdapter) global.MochiHostAdapter.register(adapter);
  if (typeof module === "object" && module.exports) module.exports = adapter;
})(typeof globalThis !== "undefined" ? globalThis : window);
