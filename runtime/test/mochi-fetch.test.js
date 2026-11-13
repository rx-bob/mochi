const test = require("node:test");
const assert = require("node:assert/strict");

let adapter;
global.MochiHostAdapter = {
  register(spec) { adapter = spec; },
};
require("../mochi-fetch.js");

function responseFromChunks(chunks, options = {}) {
  let cancelled = false;
  const body = new ReadableStream({
    start(controller) {
      chunks.forEach((chunk) => controller.enqueue(new TextEncoder().encode(chunk)));
      controller.close();
    },
    cancel() { cancelled = true; },
  });
  return {
    status: options.status || 200,
    ok: options.ok !== false,
    statusText: options.statusText || "OK",
    headers: { get: (name) => name === "content-type" ? "application/json" : null },
    body,
    wasCancelled: () => cancelled,
  };
}

test("network adapter streams a response within its immutable operation limit", async () => {
  const response = responseFromChunks(['{"items":', '[1,2]}']);
  global.fetch = async () => response;
  const envelope = await adapter.async.fetch(
    JSON.stringify({ url: "/api/items", options: {} }),
    Object.freeze({ response_bytes: 32 }),
  );

  assert.deepEqual(envelope, {
    status: 200,
    ok: true,
    body: '{"items":[1,2]}',
    data: { items: [1, 2] },
    error: null,
  });
});

test("network adapter cancels a response as soon as its configured limit is exceeded", async () => {
  const response = responseFromChunks([]);
  let cancelled = false;
  const chunks = ["1234", "5678"].map((chunk) => new TextEncoder().encode(chunk));
  let next = 0;
  response.body = {
    getReader() {
      return {
        async read() {
          if (next < chunks.length) return { done: false, value: chunks[next++] };
          return { done: true };
        },
        async cancel() { cancelled = true; },
        releaseLock() {},
      };
    },
  };
  global.fetch = async () => response;
  const envelope = await adapter.async.fetch(
    JSON.stringify({ url: "/api/large", options: {} }),
    { response_bytes: 6 },
  );

  assert.equal(cancelled, true);
  assert.equal(envelope.ok, false);
  assert.equal(envelope.body, "");
  assert.match(envelope.error, /exceeds configured byte limit 6/);
});

test("network adapter rejects missing limits without starting fetch", async () => {
  let calls = 0;
  global.fetch = async () => { calls += 1; };
  const envelope = await adapter.async.fetch(
    JSON.stringify({ url: "/api/items", options: {} }),
    {},
  );

  assert.equal(calls, 0);
  assert.equal(envelope.ok, false);
  assert.match(envelope.error, /no valid response byte limit/);
});
