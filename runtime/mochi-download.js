// Bounded, one-shot Blob downloads. Accepted URLs outlive mount disposal.
(function (global) {
  "use strict";
  var LEASE_MS = 30000;

  function create(environment) {
    var env = environment || global;
    var leases = new Map();
    var retained = 0;
    function fail(message) { throw new Error("download: " + message); }
    function release(url) {
      var lease = leases.get(url);
      if (!lease) return;
      try { env.URL.revokeObjectURL(url); }
      finally { leases.delete(url); retained -= lease.bytes; }
    }
    function scheduleRelease(url) {
      return env.setTimeout(function () { release(url); }, LEASE_MS);
    }
    function save(filename, type, parts, limits, context) {
      if (!context || !context.isLive()) fail("component mount is stale");
      if (!limits || ![limits.bytes, limits.retained_bytes, limits.leases].every(function (n) {
        return Number.isSafeInteger(n) && n > 0;
      })) fail("invalid capability limits");
      if (typeof filename !== "string" || !filename || filename === "." || filename === ".." ||
          /[\x00-\x1f\x7f/\\]/.test(filename) || new TextEncoder().encode(filename).length > 255) {
        fail("filename must be a basename of 1–255 UTF-8 bytes without control characters");
      }
      if (typeof type !== "string" || type.length > 127 ||
          !/^[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+(?:;charset=utf-8)?$/.test(type)) {
        fail("content type must be a MIME type, optionally with ;charset=utf-8");
      }
      if (!Array.isArray(parts) || parts.length > 1024) fail("at most 1024 byte parts are supported");
      var bytes = 0;
      parts.forEach(function (part) {
        if (!(part instanceof Uint8Array)) fail("parts must contain bytes");
        bytes += part.byteLength;
        if (bytes > limits.bytes) fail("content exceeds configured byte limit");
      });
      if (!env.navigator.userActivation || !env.navigator.userActivation.isActive) {
        fail("a current user activation is required; use a click or keyboard action");
      }
      if (leases.size >= limits.leases || retained + bytes > limits.retained_bytes) {
        fail("pending downloads exceed configured retention limits; retry after 30 seconds");
      }
      var url, anchor, timer, accepted = false;
      try {
        var blob = new env.Blob(parts, {type:type});
        url = env.URL.createObjectURL(blob);
        leases.set(url, { bytes: bytes, owner: context.owner, mountToken: context.mountToken });
        retained += bytes;
        // Schedule before click so a timer failure cannot report success.
        timer = scheduleRelease(url);
        anchor = env.document.createElement("a");
        anchor.download = filename;
        anchor.href = url;
        anchor.hidden = true;
        env.document.body.appendChild(anchor);
        anchor.click();
        accepted = true;
      } finally {
        try { if (anchor) anchor.remove(); }
        finally {
          if (!accepted && url) {
            if (timer !== undefined) env.clearTimeout(timer);
            release(url);
          }
        }
      }
      // Success means browser handoff, not confirmation of a disk write.
      return true;
    }
    return {
      name: "download", version: 1, sync: { save: save },
      disposeOwner: function (owner, token) {
        leases.forEach(function (lease) {
          if (lease.owner === owner && lease.mountToken === token) {
            lease.owner = null; lease.mountToken = null;
          }
        });
      },
      debugStats: function () { return { urls: leases.size, bytes: retained }; }
    };
  }
  var host = create();
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) {
    module.exports = host;
    module.exports.create = create;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
