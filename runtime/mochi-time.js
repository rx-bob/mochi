// Optional wall clock. No timers, callbacks, or retained owners.
(function (global) {
  "use strict";

  var MAX_MILLISECONDS = 8640000000000000;

  // Internal injection seam: tests supply a clock without changing global Date.
  function create(nowMilliseconds) {
    return {
      name: "time",
      version: 1,
      sync: {
        now: function (argsJson) {
          var args = JSON.parse(argsJson);
          if (!Array.isArray(args) || args.length !== 0) {
            throw new Error("time: now takes no arguments");
          }
          var value = nowMilliseconds();
          if (!Number.isSafeInteger(value) || Math.abs(value) > MAX_MILLISECONDS) {
            throw new Error("time: clock must return integer Unix milliseconds within the supported range");
          }
          return value;
        }
      }
    };
  }

  var host = create(function () { return Date.now(); });
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) {
    module.exports = host;
    module.exports.create = create;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
