const test = require("node:test");
const assert = require("node:assert/strict");

const adapter = require("../mochi-files.js");
const context = { owner: "17", mountToken: 4 };
const limits = { handles: 3, metadata_bytes: 2048 };

function file(name, size, type = "", lastModified = 0) {
  return { name, size, type, lastModified };
}

test("file input snapshots metadata and retains opaque host references", () => {
  const input = { type: "file", files: [file("empty.bin", 0), file("report.txt", 12, "text/plain", 1234)] };
  const snapshot = adapter.snapshotInput({ target: input }, context, limits);
  assert.equal(snapshot.files.length, 2);
  assert.deepEqual(Object.keys(snapshot.files[0]).sort(), ["handle", "last_modified", "name", "size", "type"]);
  assert.equal(snapshot.files[0].size, 0);
  assert.equal(snapshot.files[0].type, "");
  assert.equal(snapshot.files[1].type, "text/plain");
  assert.equal(adapter.get(snapshot.files[1].handle).file, input.files[1]);
  assert.equal(Object.values(snapshot).some((value) => value === input.files[0]), false);
  snapshot.files.forEach((entry) => adapter.release(entry.handle, "17", 4));
});

test("dropped files are accepted during dragover and snapshotted without file bytes", () => {
  let prevented = false;
  const dragover = { dataTransfer: { types: ["Files"] }, preventDefault() { prevented = true; } };
  assert.equal(adapter.allowDrop(dragover), true);
  assert.equal(prevented, true);
  const snapshot = adapter.snapshotDrop({ dataTransfer: { files: [file("mystery", 7)] } }, context, limits);
  assert.equal(snapshot.files[0].name, "mystery");
  assert.equal(snapshot.files[0].type, "");
  assert.equal(Object.hasOwn(snapshot.files[0], "bytes"), false);
  adapter.release(snapshot.files[0].handle, "17", 4);
});

test("batch count and metadata limits fail before any handle is published", () => {
  assert.throws(() => adapter.snapshotInput({ target: { files: [file("a", 1), file("b", 1), file("c", 1), file("d", 1)] } }, context, limits), /handle limit/);
  assert.equal(adapter.count(), 0);
  assert.throws(() => adapter.snapshotInput({ target: { files: [file("x".repeat(3000), 1)] } }, context, limits), /metadata/);
  assert.equal(adapter.count(), 0);
});

test("explicit release validates owner and generation; unmount clears remaining handles", () => {
  const snapshot = adapter.snapshotInput({ target: { files: [file("one", 1), file("two", 2)] } }, context, limits);
  const [one, two] = snapshot.files;
  assert.throws(() => adapter.release(one.handle, "other", 4), /another component mount/);
  assert.throws(() => adapter.release(one.handle, "17", 5), /another component mount/);
  assert.equal(adapter.release(one.handle, "17", 4), true);
  assert.throws(() => adapter.release(one.handle, "17", 4), /stale/);
  assert.equal(adapter.releaseOwner("17", 4), 1);
  assert.equal(adapter.count(), 0);
  const reused = adapter.snapshotInput({ target: { files: [file("new", 1)] } }, context, limits).files[0];
  assert.notEqual(reused.handle, two.handle);
  adapter.discardBatch([reused]);
});

test("file drops with no files do not claim the gesture", () => {
  let prevented = false;
  const event = { dataTransfer: { files: [], types: ["text/plain"] }, preventDefault() { prevented = true; } };
  assert.equal(adapter.allowDrop(event), false);
  assert.deepEqual(adapter.snapshotDrop(event, context, limits), { files: [] });
  assert.equal(prevented, false);
});

test("file readers pull bounded binary chunks and close idempotently", async () => {
  const source = new Blob([Uint8Array.from({ length: 256 }, (_, index) => index)]);
  Object.defineProperties(source, { name: { value: "bytes.bin" }, lastModified: { value: 0 } });
  const context = { owner: "reader-owner", mountToken: 8 };
  const readerLimits = { ...limits, readers: 1, chunk_bytes: 37, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, readerLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, readerLimits);
  const seen = [];
  let result;
  do {
    result = await adapter.async.read_next(JSON.stringify([metadata.handle]), readerLimits, context);
    if (result.state === "chunk") {
      const encoded = result.bytes.__mochi_bytes;
      seen.push(...Buffer.from(encoded, "base64"));
      assert.ok(result.next_offset - result.offset <= readerLimits.chunk_bytes);
    }
  } while (result.state === "chunk");
  assert.deepEqual(seen, Array.from({ length: 256 }, (_, index) => index));
  assert.equal(result.state, "eof");
  assert.equal(adapter.readerCount(), 0);
  adapter.sync.close(metadata.handle, context.owner, context.mountToken, readerLimits);
  adapter.sync.close(metadata.handle, context.owner, context.mountToken, readerLimits);
  assert.equal(adapter.readerCount(), 0);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("file reader slots are bounded and owner disposal cancels readers", () => {
  const source = new Blob(["content"]);
  Object.defineProperties(source, { name: { value: "owned.bin" }, lastModified: { value: 0 } });
  const context = { owner: "reader-limit", mountToken: 9 };
  const readerLimits = { ...limits, readers: 1, chunk_bytes: 4, envelope_bytes: 1024 };
  const files = adapter.snapshotInput({ target: { files: [source, source] } }, context, readerLimits).files;
  adapter.sync.open(files[0].handle, context.owner, context.mountToken, readerLimits);
  assert.throws(() => adapter.sync.open(files[1].handle, context.owner, context.mountToken, readerLimits), /reader limit/);
  adapter.disposeOwner(context.owner, context.mountToken);
  assert.equal(adapter.readerCount(), 0);
  assert.equal(adapter.count(), 0);
});

test("closing an in-flight pull cancels its bounded Blob reader", async () => {
  let cancelled = false;
  const source = {
    name: "slow.bin", size: 4, lastModified: 0,
    slice(start, end) {
      assert.equal(end - start, 4);
      return {
        stream() {
          return new ReadableStream({
            pull() {},
            cancel() { cancelled = true; },
          });
        },
      };
    },
  };
  const context = { owner: "slow-owner", mountToken: 10 };
  const readerLimits = { ...limits, readers: 1, chunk_bytes: 4, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, readerLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, readerLimits);
  const pending = adapter.async.read_next(JSON.stringify([metadata.handle]), readerLimits, context);
  await Promise.resolve();
  assert.throws(
    () => adapter.async.read_next(JSON.stringify([metadata.handle]), readerLimits, context),
    /in flight/,
  );
  adapter.sync.close(metadata.handle, context.owner, context.mountToken, readerLimits);
  await assert.rejects(pending, /closed/);
  assert.equal(cancelled, true);
  assert.equal(adapter.readerCount(), 0);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("stream failures release the reader slot and return a deterministic error", async () => {
  const source = {
    name: "broken.bin", size: 4, lastModified: 0,
    slice() {
      return { stream: () => new ReadableStream({ start(controller) { controller.error(new Error("fixture read failure")); } }) };
    },
  };
  const context = { owner: "error-owner", mountToken: 11 };
  const readerLimits = { ...limits, readers: 1, chunk_bytes: 4, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, readerLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, readerLimits);
  await assert.rejects(
    adapter.async.read_next(JSON.stringify([metadata.handle]), readerLimits, context),
    /fixture read failure/,
  );
  assert.equal(adapter.readerCount(), 0);
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, readerLimits);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("bounded whole-file reads assemble exact bytes from capped slices", async () => {
  const source = new Blob([Uint8Array.from({ length: 256 }, (_, index) => index)]);
  Object.defineProperties(source, { name: { value: "binary.bin" }, lastModified: { value: 0 } });
  const originalSlice = source.slice.bind(source);
  const ranges = [];
  source.slice = (start, end) => {
    ranges.push([start, end]);
    assert.ok(end - start <= 37);
    return originalSlice(start, end);
  };
  const context = { owner: "whole-owner", mountToken: 12 };
  const wholeLimits = { ...limits, readers: 1, chunk_bytes: 37, whole_read_bytes: 256, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, wholeLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, wholeLimits);
  const result = await adapter.async.read(JSON.stringify([metadata.handle]), wholeLimits, context);
  assert.deepEqual([...Buffer.from(result.__mochi_bytes, "base64")], Array.from({ length: 256 }, (_, index) => index));
  assert.ok(ranges.length > 1);
  assert.deepEqual(ranges[0], [0, 37]);
  assert.equal(ranges.at(-1)[1], 256);
  assert.equal(adapter.readerCount(), 0);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("oversized whole-file reads reject before slicing and free their slot", async () => {
  let slices = 0;
  const source = {
    name: "too-large.bin", size: 5, lastModified: 0,
    slice() { slices += 1; throw new Error("must not read"); },
  };
  const context = { owner: "oversized-owner", mountToken: 13 };
  const wholeLimits = { ...limits, readers: 1, chunk_bytes: 4, whole_read_bytes: 4, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, wholeLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, wholeLimits);
  await assert.rejects(
    adapter.async.read(JSON.stringify([metadata.handle]), wholeLimits, context),
    /whole-file read limit/,
  );
  assert.equal(slices, 0);
  assert.equal(adapter.readerCount(), 0);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("text reads preserve split UTF-8 sequences and reject malformed or unsupported encodings", async () => {
  const source = new Blob(["a".repeat(35) + "€" + "z"]);
  Object.defineProperties(source, { name: { value: "split.txt" }, lastModified: { value: 0 } });
  const context = { owner: "text-owner", mountToken: 14 };
  const wholeLimits = { ...limits, readers: 1, chunk_bytes: 37, whole_read_bytes: 100, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, wholeLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, wholeLimits);
  const result = await adapter.async.read_text(JSON.stringify([metadata.handle, "UTF-8"]), wholeLimits, context);
  assert.equal(Buffer.from(result.__mochi_bytes, "base64").toString("utf8"), "a".repeat(35) + "€z");
  adapter.release(metadata.handle, context.owner, context.mountToken);

  const malformed = {
    name: "malformed.txt", size: 2, lastModified: 0,
    slice(start, end) {
      return new Blob([Uint8Array.from([0x61, 0xff]).slice(start, end)]);
    },
  };
  const bad = adapter.snapshotInput({ target: { files: [malformed] } }, context, wholeLimits).files[0];
  adapter.sync.open(bad.handle, context.owner, context.mountToken, wholeLimits);
  await assert.rejects(
    adapter.async.read_text(JSON.stringify([bad.handle, "UTF-8"]), wholeLimits, context),
    /malformed UTF-8/,
  );
  assert.equal(adapter.readerCount(), 0);
  adapter.release(bad.handle, context.owner, context.mountToken);

  const unsupported = adapter.snapshotInput({ target: { files: [file("unsupported.txt", 1)] } }, context, wholeLimits).files[0];
  adapter.sync.open(unsupported.handle, context.owner, context.mountToken, wholeLimits);
  await assert.rejects(
    adapter.async.read_text(JSON.stringify([unsupported.handle, "Shift_JIS"]), wholeLimits, context),
    /only UTF-8 is supported/,
  );
  assert.equal(adapter.readerCount(), 0);
  adapter.release(unsupported.handle, context.owner, context.mountToken);
});

test("closing an in-flight whole-file read cancels its callback path", async () => {
  let cancelled = false;
  const source = {
    name: "slow-whole.bin", size: 4, lastModified: 0,
    slice() {
      return {
        stream: () => new ReadableStream({ pull() {}, cancel() { cancelled = true; } }),
      };
    },
  };
  const context = { owner: "cancel-whole-owner", mountToken: 15 };
  const wholeLimits = { ...limits, readers: 1, chunk_bytes: 4, whole_read_bytes: 4, envelope_bytes: 1024 };
  const metadata = adapter.snapshotInput({ target: { files: [source] } }, context, wholeLimits).files[0];
  adapter.sync.open(metadata.handle, context.owner, context.mountToken, wholeLimits);
  const pending = adapter.async.read(JSON.stringify([metadata.handle]), wholeLimits, context);
  adapter.sync.close(metadata.handle, context.owner, context.mountToken, wholeLimits);
  await assert.rejects(pending, /closed/);
  assert.equal(cancelled, true);
  assert.equal(adapter.readerCount(), 0);
  adapter.release(metadata.handle, context.owner, context.mountToken);
});

test("whole-file conveniences serialize and recover their bounded reader slot", async () => {
  let cancelled = false;
  const slow = {
    name: "slow.bin", size: 1, lastModified: 0,
    slice() {
      return { stream: () => new ReadableStream({ pull() {}, cancel() { cancelled = true; } }) };
    },
  };
  const quick = new Blob(["x"]);
  Object.defineProperties(quick, { name: { value: "quick.bin" }, lastModified: { value: 0 } });
  const context = { owner: "whole-slot-owner", mountToken: 16 };
  const wholeLimits = { ...limits, readers: 2, chunk_bytes: 4, whole_read_bytes: 4, envelope_bytes: 1024 };
  const files = adapter.snapshotInput({ target: { files: [slow, quick] } }, context, wholeLimits).files;
  adapter.sync.open(files[0].handle, context.owner, context.mountToken, wholeLimits);
  adapter.sync.open(files[1].handle, context.owner, context.mountToken, wholeLimits);
  const pending = adapter.async.read(JSON.stringify([files[0].handle]), wholeLimits, context);
  await assert.rejects(
    adapter.async.read(JSON.stringify([files[1].handle]), wholeLimits, context),
    /another whole-file read is already active/,
  );
  adapter.sync.close(files[0].handle, context.owner, context.mountToken, wholeLimits);
  await assert.rejects(pending, /closed/);
  assert.equal(cancelled, true);
  adapter.sync.open(files[1].handle, context.owner, context.mountToken, wholeLimits);
  const recovered = await adapter.async.read(JSON.stringify([files[1].handle]), wholeLimits, context);
  assert.equal(Buffer.from(recovered.__mochi_bytes, "base64").toString(), "x");
  adapter.release(files[0].handle, context.owner, context.mountToken);
  adapter.release(files[1].handle, context.owner, context.mountToken);
});
