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
