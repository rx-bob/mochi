const {test} = require("node:test");
const assert = require("node:assert/strict");
const {create} = require("../mochi-download.js");

function setup() {
  const timers = new Map(), urls = new Map(), clicks = [];
  let next = 0, failAt = "";
  const env = {
    navigator: {userActivation: {isActive: true}},
    Blob: class extends Blob { constructor(parts, options) { if (failAt === "blob") throw Error("blob failed"); super(parts, options); } },
    URL: {
      createObjectURL(blob) { if (failAt === "url") throw Error("url failed"); const url = `blob:${++next}`; urls.set(url, blob); return url; },
      revokeObjectURL(url) { urls.delete(url); }
    },
    setTimeout(fn, ms) { assert.equal(ms, 30000); if (failAt === "timer") throw Error("timer failed"); timers.set(next, fn); return next; },
    clearTimeout(id) { timers.delete(id); },
    document: {body: {appendChild() { if (failAt === "append") throw Error("append failed"); }},
      createElement() { return {click() { if (failAt === "click") throw Error("click failed"); clicks.push({filename:this.download, url:this.href}); }, remove() {}}; }}
  };
  return {env, urls, timers, clicks, host:create(env), fail(value) { failAt=value; },
    expire() { for (const fn of timers.values()) fn(); timers.clear(); }};
}
const limits = {bytes: 32, retained_bytes: 64, leases: 2};
const context = {owner:"1", mountToken:1, isLive:()=>true};
const bytes = new Uint8Array([0,128,255]);

test("download keeps exact bytes/MIME and accepted URLs survive disposal until lease expiry", async () => {
  const s=setup();
  assert.equal(s.host.sync.save("résumé.bin", "application/octet-stream", [bytes], limits, context), true);
  const blob=s.urls.get(s.clicks[0].url);
  assert.equal(blob.type,"application/octet-stream");
  assert.deepEqual([...new Uint8Array(await blob.arrayBuffer())],[0,128,255]);
  assert.equal(s.clicks[0].filename,"résumé.bin");
  s.host.disposeOwner("1",1);
  assert.equal(s.urls.size,1);
  assert.deepEqual(s.host.debugStats(),{urls:1,bytes:3});
  s.expire();
  assert.equal(s.urls.size,0);
  assert.deepEqual(s.host.debugStats(),{urls:0,bytes:0});
});

test("download validates activation, owner, metadata and byte/count limits before allocation", () => {
  const s=setup(), save=(name="ok.txt", type="text/plain", parts=[bytes], ctx=context) => s.host.sync.save(name,type,parts,limits,ctx);
  s.env.navigator.userActivation.isActive=false;
  assert.throws(()=>save(),/current user activation/);
  s.env.navigator.userActivation.isActive=true;
  assert.throws(()=>save("ok","text/plain",[bytes],{isLive:()=>false}),/mount is stale/);
  for(const name of ["", "../x", "a\\b", "a\n", ".", "é".repeat(128)]) assert.throws(()=>save(name),/filename/);
  for(const type of ["", "bad", "text/plain\n", "text/plain;foo=bar"]) assert.throws(()=>save("x",type),/content type/);
  assert.throws(()=>save("x","text/plain",[new Uint8Array(33)]),/byte limit/);
  assert.throws(()=>save("x","text/plain",Array(1025).fill(bytes)),/1024/);
  assert.equal(s.urls.size,0);
  save(); save();
  assert.throws(()=>save(),/retention limits/);
  s.expire(); save();
  s.expire(); assert.equal(s.urls.size,0);
  const budget = {...limits, retained_bytes: 5};
  s.host.sync.save("x", "text/plain", [bytes], budget, context);
  assert.throws(() => s.host.sync.save("x", "text/plain", [bytes], budget, context), /retention limits/);
  s.expire();
  s.host.sync.save("x", "text/plain", [bytes], budget, context);
  s.expire();
});

test("failures release URLs and timers; repeated successful downloads release after handoff", () => {
  const s=setup();
  for(const stage of ["blob","url","timer","append","click"]) {
    s.fail(stage);
    assert.throws(()=>s.host.sync.save("x","text/plain",[bytes],limits,context),/failed/);
    assert.deepEqual(s.host.debugStats(),{urls:0,bytes:0});
    assert.equal(s.urls.size,0); assert.equal(s.timers.size,0);
  }
  s.fail("");
  for(let i=0;i<50;i++) {
    s.host.sync.save("x","text/plain",[],limits,context);
    assert.equal(s.urls.size,1);
    s.expire(); assert.equal(s.urls.size,0);
  }
});
