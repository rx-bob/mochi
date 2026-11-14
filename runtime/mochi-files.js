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
    var readers = new Map();
    var wholeReads = 0;
    var nextId = 1;

    function ownerMatches(record, context) {
      return record && context && record.owner === String(context.owner) &&
        record.mountToken === context.mountToken;
    }

    function cancelReader(handle, context) {
      var reader = readers.get(handle);
      if (!reader) return false;
      if (context && !ownerMatches(reader, context)) fail("reader belongs to another component mount");
      readers.delete(handle);
      if (reader.wholeRead) {
        wholeReads -= 1;
        reader.wholeRead = false;
      }
      reader.closed = true;
      if (reader.streamReader) {
        try {
          var cancellation = reader.streamReader.cancel();
          if (cancellation && typeof cancellation.catch === "function") cancellation.catch(function () {});
        } catch (_) {}
      }
      return true;
    }

    function openReader(handle, owner, mountToken, limits) {
      if (typeof handle !== "string" || !handle) fail("open expects a file handle");
      var file = handles.get(handle);
      if (!file || file.owner !== String(owner) || file.mountToken !== mountToken) {
        fail("file handle is stale or belongs to another component mount");
      }
      var existing = readers.get(handle);
      if (existing) {
        if (existing.inFlight) fail("reader already has a chunk in flight");
        return handle;
      }
      if (readers.size >= limits.readers) fail("active readers exceed configured reader limit");
      readers.set(handle, {
        owner: String(owner), mountToken: mountToken, file: file.file,
        offset: 0, inFlight: false, streamReader: null, wholeRead: false, closed: false
      });
      return handle;
    }

    function encodeBase64(bytes) {
      var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      var out = "";
      for (var i = 0; i < bytes.length; i += 3) {
        var a = bytes[i], hasB = i + 1 < bytes.length, hasC = i + 2 < bytes.length;
        var b = hasB ? bytes[i + 1] : 0, c = hasC ? bytes[i + 2] : 0;
        out += alphabet[a >> 2] + alphabet[((a & 3) << 4) | (b >> 4)] +
          (hasB ? alphabet[((b & 15) << 2) | (c >> 6)] : "=") +
          (hasC ? alphabet[c & 63] : "=");
      }
      return out;
    }

    function readNext(argsJson, limits, context) {
      var args = JSON.parse(argsJson);
      var handle = args && args[0];
      var record = readers.get(handle);
      if (!ownerMatches(record, context) || record.closed) fail("reader is stale or belongs to another mount");
      if (record.inFlight) fail("reader already has a chunk in flight");
      if (record.offset >= record.file.size) {
        cancelReader(handle, context);
        return Promise.resolve({ state: "eof", offset: record.offset, total: record.file.size });
      }
      var start = record.offset;
      var end = Math.min(start + limits.chunk_bytes, record.file.size);
      record.inFlight = true;
      var generation = record;
      var bytes = new Uint8Array(limits.chunk_bytes);
      var used = 0;
      var streamReader;
      try {
        var slice = record.file.slice(start, end);
        if (!slice || typeof slice.stream !== "function") {
          throw new Error("bounded file streaming is unavailable");
        }
        streamReader = slice.stream().getReader();
      } catch (error) {
        cancelReader(handle, context);
        var message = error && error.message ? error.message : String(error);
        return Promise.reject(new Error(message.slice(0, 128) || "file read failed"));
      }
      record.streamReader = streamReader;
      function finish(value) {
        if (readers.get(handle) !== generation || generation.closed) throw new Error("file reader was closed");
        generation.streamReader = null;
        generation.inFlight = false;
        return value;
      }
      function pump() {
        return streamReader.read().then(function (result) {
          if (readers.get(handle) !== generation || generation.closed) throw new Error("file reader was closed");
          if (result.done) {
            if (used !== end - start) throw new Error("file source ended before the requested byte range");
            var data = bytes.subarray(0, used);
            var value = {
              state: "chunk", offset: start, next_offset: start + used, total: generation.file.size,
              bytes: { __mochi_bytes: encodeBase64(data) }
            };
            var envelope = { ok: true, value: value, error: null };
            if (byteLength(JSON.stringify(envelope)) > limits.envelope_bytes) {
              throw new Error("file chunk envelope exceeds configured host inbox capacity");
            }
            generation.offset = start + used;
            return finish(value);
          }
          var value = result.value;
          if (!value || !Number.isSafeInteger(value.length) || used + value.length > limits.chunk_bytes ||
              used + value.length > end - start) {
            throw new Error("file source exceeded configured chunk size");
          }
          bytes.set(value, used);
          used += value.length;
          return pump();
        });
      }
      return pump().catch(function (error) {
        if (readers.get(handle) === generation && !generation.closed) {
          cancelReader(handle, context);
        }
        var message = error && error.message ? error.message : String(error);
        throw new Error(message.slice(0, 128) || "file read failed");
      });
    }

    function readWhole(argsJson, limits, context, textMode) {
      var args = JSON.parse(argsJson);
      var handle = args && args[0];
      var record = readers.get(handle);
      if (!ownerMatches(record, context) || record.closed) fail("reader is stale or belongs to another mount");
      if (record.inFlight) fail("reader already has a read in flight");
      var encoding = args && args[1];
      if (textMode && (typeof encoding !== "string" || !/^utf-?8$/i.test(encoding))) {
        cancelReader(handle, context);
        return Promise.reject(new Error("unsupported file text encoding; only UTF-8 is supported"));
      }
      if (record.offset !== 0) {
        cancelReader(handle, context);
        return Promise.reject(new Error("whole-file reads require a newly opened reader"));
      }
      var size = record.file.size;
      if (size > limits.whole_read_bytes) {
        cancelReader(handle, context);
        return Promise.reject(new Error("file exceeds configured whole-file read limit"));
      }
      if (wholeReads >= 1) {
        cancelReader(handle, context);
        return Promise.reject(new Error("another whole-file read is already active"));
      }

      record.inFlight = true;
      var output = new Uint8Array(size);
      var decoder;
      try {
        if (textMode) decoder = new TextDecoder("utf-8", { fatal: true });
      } catch (_) {
        cancelReader(handle, context);
        return Promise.reject(new Error("strict UTF-8 decoding is unavailable in this browser"));
      }
      wholeReads += 1;
      record.wholeRead = true;
      var offset = 0;

      function readPart() {
        if (readers.get(handle) !== record || record.closed) {
          return Promise.reject(new Error("file reader was closed"));
        }
        if (offset >= size) {
          try {
            if (decoder) decoder.decode();
          } catch (_) {
            return Promise.reject(new Error("file contains malformed UTF-8"));
          }
          var value = { __mochi_bytes: encodeBase64(output) };
          if (byteLength(JSON.stringify({ ok: true, value: value, error: null })) > limits.envelope_bytes) {
            return Promise.reject(new Error("whole-file result exceeds configured host inbox capacity"));
          }
          record.offset = size;
          cancelReader(handle, context);
          return Promise.resolve(value);
        }

        var start = offset;
        var end = Math.min(start + limits.chunk_bytes, size);
        var part = new Uint8Array(limits.chunk_bytes);
        var used = 0;
        var streamReader;
        try {
          var slice = record.file.slice(start, end);
          if (!slice || typeof slice.stream !== "function") {
            throw new Error("bounded file streaming is unavailable");
          }
          streamReader = slice.stream().getReader();
          record.streamReader = streamReader;
        } catch (error) {
          var message = error && error.message ? error.message : String(error);
          return Promise.reject(new Error(message.slice(0, 128) || "file read failed"));
        }

        function pumpPart() {
          return streamReader.read().then(function (result) {
            if (readers.get(handle) !== record || record.closed) throw new Error("file reader was closed");
            if (result.done) {
              if (used !== end - start) throw new Error("file source ended before the requested byte range");
              var bytes = part.subarray(0, used);
              if (decoder) {
                try {
                  decoder.decode(bytes, { stream: true });
                } catch (_) {
                  throw new Error("file contains malformed UTF-8");
                }
              }
              output.set(bytes, start);
              offset = end;
              record.streamReader = null;
              return readPart();
            }
            var incoming = result.value;
            if (!incoming || !Number.isSafeInteger(incoming.length) ||
                used + incoming.length > limits.chunk_bytes || used + incoming.length > end - start) {
              throw new Error("file source exceeded configured chunk size");
            }
            part.set(incoming, used);
            used += incoming.length;
            return pumpPart();
          });
        }
        return pumpPart();
      }

      return readPart().catch(function (error) {
        if (readers.get(handle) === record && !record.closed) cancelReader(handle, context);
        var message = error && error.message ? error.message : String(error);
        throw new Error(message.slice(0, 128) || "file read failed");
      });
    }

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
      cancelReader(handle, { owner: owner, mountToken: mountToken });
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
      readers.forEach(function (reader, handle) {
        if (reader.owner === String(owner) && reader.mountToken === mountToken) {
          cancelReader(handle, { owner: owner, mountToken: mountToken });
        }
      });
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
        },
        open: openReader,
        close: function (handle, owner, mountToken) {
          var file = handles.get(handle);
          if (!file || file.owner !== String(owner) || file.mountToken !== mountToken) {
            fail("reader handle is stale or belongs to another mount");
          }
          return cancelReader(handle, { owner: owner, mountToken: mountToken });
        }
      },
      async: {
        read_next: readNext,
        read: function (argsJson, limits, context) { return readWhole(argsJson, limits, context, false); },
        read_text: function (argsJson, limits, context) { return readWhole(argsJson, limits, context, true); }
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
      disposeOwner: function (owner, mountToken) { releaseOwner(owner, mountToken); },
      discardBatch: discardBatch,
      get: function (handle) { return handles.get(handle); },
      count: function () { return handles.size; },
      readerCount: function () { return readers.size; }
    };
  }

  var host = createAdapter();
  if (global.MochiHostAdapter && typeof global.MochiHostAdapter.register === "function") {
    global.MochiHostAdapter.register(host);
  }
  if (typeof module === "object" && module.exports) module.exports = host;
})(typeof globalThis !== "undefined" ? globalThis : window);
