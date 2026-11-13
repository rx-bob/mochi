// Optional file metadata and opaque-handle adapter. File objects stay on the
// host and are retained only while their mount-owned handle remains live.
(function (global) {
  "use strict";

  function fail(message) {
    throw new Error("files: " + message);
  }

  function byteLength(text) {
    return typeof TextEncoder === "function"
      ? new TextEncoder().encode(text).length
      : unescape(encodeURIComponent(text)).length;
  }

  function filesFrom(event, input) {
    if (!event) return [];
    if (input) return event.target && event.target.files
      ? Array.prototype.slice.call(event.target.files) : [];
    return event.dataTransfer && event.dataTransfer.files
      ? Array.prototype.slice.call(event.dataTransfer.files) : [];
  }

  function fileTypes(event) {
    var types = event && event.dataTransfer && event.dataTransfer.types;
    return Array.prototype.slice.call(types || []);
  }

  function createAdapter() {
    var handles = new Map();
    var owners = new Map();
    var nextId = 1;

    function snapshot(event, context, limits, input) {
      var files = filesFrom(event, input);
      if (files.length === 0) return { files: [] };
      if (!context || !context.owner || !context.mountToken) fail("file event has no live mount owner");
      if (files.length > limits.handles) fail("file count exceeds configured handle limit");

      var ownerKey = String(context.owner) + ":" + String(context.mountToken);
      var ownerHandles = owners.get(ownerKey) || new Set();
      if (handles.size + files.length > limits.handles) {
        fail("active file handles exceed configured handle limit");
      }

      var pending = [];
      files.forEach(function (file) {
        if (!file || typeof file.name !== "string" ||
            !Number.isSafeInteger(Number(file.size)) || Number(file.size) < 0) {
          fail("browser supplied invalid file metadata");
        }
        var modified = Number(file.lastModified);
        if (!Number.isFinite(modified) || modified < 0) modified = 0;
        var metadata = {
          handle: "mochi-file-" + String(nextId + pending.length),
          name: file.name,
          size: Number(file.size),
          type: typeof file.type === "string" ? file.type : "",
          last_modified: modified
        };
        pending.push({ file: file, metadata: metadata });
      });

      var combined = pending.map(function (record) { return record.metadata; });
      if (byteLength(JSON.stringify(combined)) > limits.metadata_bytes) {
        fail("file metadata exceeds configured event payload limit");
      }
      if (nextId + pending.length > Number.MAX_SAFE_INTEGER) {
        fail("file handle generation exhausted");
      }

      // Publish only after the complete batch passes every count and metadata check.
      pending.forEach(function (record) {
        var handle = record.metadata.handle;
        handles.set(handle, {
          file: record.file,
          owner: String(context.owner),
          mountToken: context.mountToken,
          ownerKey: ownerKey
        });
        ownerHandles.add(handle);
      });
      nextId += pending.length;
      owners.set(ownerKey, ownerHandles);
      return { files: combined };
    }

    function release(handle, owner, mountToken) {
      if (typeof handle !== "string" || !handle) fail("release expects a file handle");
      var record = handles.get(handle);
      if (!record) fail("file handle is stale or already released");
      if (record.owner !== String(owner) || record.mountToken !== mountToken) {
        fail("file handle belongs to another component mount");
      }
      handles.delete(handle);
      var ownerHandles = owners.get(record.ownerKey);
      if (ownerHandles) {
        ownerHandles.delete(handle);
        if (ownerHandles.size === 0) owners.delete(record.ownerKey);
      }
      return true;
    }

    function releaseOwner(owner, mountToken) {
      var ownerKey = String(owner) + ":" + String(mountToken);
      var ownerHandles = owners.get(ownerKey);
      if (!ownerHandles) return 0;
      ownerHandles.forEach(function (handle) { handles.delete(handle); });
      var count = ownerHandles.size;
      owners.delete(ownerKey);
      return count;
    }

    function discardBatch(metadata) {
      (metadata || []).forEach(function (entry) {
        var record = handles.get(entry && entry.handle);
        if (!record) return;
        handles.delete(entry.handle);
        var ownerHandles = owners.get(record.ownerKey);
        if (ownerHandles) {
          ownerHandles.delete(entry.handle);
          if (ownerHandles.size === 0) owners.delete(record.ownerKey);
        }
      });
    }

    function allowDrop(event) {
      if (fileTypes(event).indexOf("Files") === -1) return false;
      event.preventDefault();
      return true;
    }

    return {
      name: "files",
      version: 1,
      sync: {
        release: function (handle, owner, mountToken) {
          return release(handle, owner, mountToken);
        }
      },
      snapshotInput: function (event, context, limits) {
        return snapshot(event, context, limits, true);
      },
      snapshotDrop: function (event, context, limits) {
        return snapshot(event, context, limits, false);
      },
      allowDrop: allowDrop,
      release: release,
      releaseOwner: releaseOwner,
      discardBatch: discardBatch,
      get: function (handle) { return handles.get(handle); },
      count: function () { return handles.size; }
    };
  }

  var host = createAdapter();
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) module.exports = host;
})(typeof globalThis !== "undefined" ? globalThis : window);
