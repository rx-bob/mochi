const test = require("node:test");
const assert = require("node:assert/strict");
const { JSDOM } = require("jsdom");
const adapter = require("../mochi-shortcuts.js");
let dom, contexts, next;
const limits = { registrations: 8 };
test.beforeEach(() => { dom = new JSDOM("<body></body>"); global.document = dom.window.document; contexts = []; next = 0; });
test.afterEach(() => { contexts.forEach(c => adapter.disposeOwner(c.owner, c.mountToken)); dom.window.close(); delete global.document; });
function scope(owner = "graph", mountToken = 1, parent = document.body) {
  const host = document.createElement("div"); parent.appendChild(host);
  const root = host.attachShadow({ mode: "open" });
  const button = document.createElement("button"); root.appendChild(button);
  const context = { owner, mountToken, request: { id: ++next, callback: "on_key" }, values: [], cancelled: 0,
    isLive: () => host.isConnected, eventScopeIndex: path => path.indexOf(host),
    cancel() { this.cancelled++; }, notify(value) { this.values.push(value); } };
  contexts.push(context);
  return { context, host, root, button };
}
function register(item, key = "z", options = {}, cap = limits) {
  return adapter.async.register(JSON.stringify([key, options]), cap, item.context);
}
function keydown(target, key = "z", options = {}) {
  const event = new dom.window.KeyboardEvent("keydown", { key, bubbles: true, composed: true, cancelable: true, ...options });
  target.dispatchEvent(event); return event;
}
test("strict modifiers, case normalization, prevention and repeats only for matching live scope", () => {
  const item = scope(); const token = register(item, "z", { ctrl: true, shift: true, prevent: true });
  assert.equal(token, item.context.request.id); assert.equal(item.context.cancelled, 1);
  assert.equal(item.context.values.length, 0); // no action on registration
  assert.equal(keydown(item.button, "Z", { ctrlKey: true, shiftKey: true }).defaultPrevented, true);
  assert.equal(item.context.values[0].token, token);
  keydown(item.button, "z", { ctrlKey: true });
  keydown(item.button, "Z", { ctrlKey: true, shiftKey: true, altKey: true });
  keydown(item.button, "Z", { ctrlKey: true, shiftKey: true, repeat: true });
  keydown(document.body, "Z", { ctrlKey: true, shiftKey: true });
  assert.equal(item.context.values.length, 1);
  adapter.async.cancel(JSON.stringify([token]), limits, item.context);
  assert.equal(keydown(item.button, "Z", { ctrlKey: true, shiftKey: true }).defaultPrevented, false);
});
test("editable composed paths and composition are ignored unless editing is explicitly allowed", () => {
  const item = scope(); register(item, "Escape", { prevent: true });
  const child = document.createElement("div"); item.root.appendChild(child);
  const nested = child.attachShadow({ mode: "open" });
  for (const tag of ["input", "textarea", "select"]) {
    const control = document.createElement(tag); nested.appendChild(control);
    assert.equal(keydown(control, "Escape").defaultPrevented, false);
  }
  const editor = document.createElement("div"); editor.contentEditable = "true"; editor.setAttribute("contenteditable", "true");
  const span = document.createElement("span"); editor.appendChild(span); nested.appendChild(editor);
  keydown(span, "Escape");
  keydown(item.button, "Escape", { isComposing: true });
  keydown(item.button, "Escape", { keyCode: 229 });
  assert.equal(item.context.values.length, 0);
  adapter.disposeOwner(item.context.owner, item.context.mountToken);
  register(item, "Escape", { allow_editable: true, repeat: true });
  keydown(span, "Escape", { repeat: true });
  assert.equal(item.context.values.length, 1);
  keydown(span, "Escape", { isComposing: true });
  assert.equal(item.context.values.length, 1);
});
test("nearest component wins, then latest registration; application owners suppress lower scopes even on unmatched keys", () => {
  const outer = scope("outer"), inner = scope("inner", 1, outer.root);
  register(outer); register(inner);
  keydown(inner.button);
  assert.equal(inner.context.values.length, 1); assert.equal(outer.context.values.length, 0);
  const duplicate = { ...inner, context: { ...inner.context, request: { id: ++next, callback: "new" }, values: [] } };
  contexts.push(duplicate.context); register(duplicate);
  keydown(inner.button); assert.equal(duplicate.context.values.length, 1); assert.equal(inner.context.values.length, 1);
  const dialog = scope("dialog"); const token = register(dialog, "Escape", { scope: "application", prevent: true, allow_editable: true });
  assert.equal(keydown(inner.button).defaultPrevented, false);
  assert.equal(duplicate.context.values.length, 1);
  assert.equal(keydown(inner.button, "Escape").defaultPrevented, true);
  assert.equal(dialog.context.values.length, 1);
  const top = scope("top"); register(top, "Escape", { scope: "application" });
  keydown(inner.button, "Escape"); assert.equal(top.context.values.length, 1); assert.equal(dialog.context.values.length, 1);
  adapter.disposeOwner("top", 1);
  keydown(inner.button, "Escape"); assert.equal(dialog.context.values.length, 2);
  adapter.async.cancel(JSON.stringify([token]), limits, dialog.context);
  keydown(inner.button); assert.equal(duplicate.context.values.length, 2);
});
test("callback cancellation fires once, disposal removes listener, stale tokens cannot cancel reused mounts", () => {
  const adds = [], removes = [];
  const add = document.addEventListener.bind(document), remove = document.removeEventListener.bind(document);
  document.addEventListener = (name, fn, options) => { if (name === "keydown") adds.push(fn); add(name, fn, options); };
  document.removeEventListener = (name, fn, options) => { if (name === "keydown") removes.push(fn); remove(name, fn, options); };
  const old = scope("same", 1); const token = register(old);
  old.context.notify = () => adapter.async.cancel(JSON.stringify([token]), limits, old.context);
  keydown(old.button); assert.equal(removes.length, 1);
  old.host.remove();
  const fresh = scope("same", 2); fresh.context.request.id = token; register(fresh);
  adapter.async.cancel(JSON.stringify([token]), limits, old.context);
  keydown(fresh.button); assert.equal(fresh.context.values.length, 1);
  fresh.host.remove(); keydown(document.body);
  assert.equal(adds.length, 2); assert.equal(removes.length, 2);
  keydown(fresh.button); assert.equal(fresh.context.values.length, 1);
});
test("validation and capacity failures leave later registrations usable", () => {
  const a = scope("a"), b = scope("b"); const small = { registrations: 1 };
  for (const options of [{ scope: "global" }, { ctrl: "true" }, { priority: 9 }, { active_ref: "" }, { active_ref: true }]) {
    assert.throws(() => register(a, "z", options), /shortcuts:/);
  }
  assert.throws(() => register(a, ""), /expected key/);
  assert.throws(() => adapter.async.cancel('[0]', limits, a.context), /cleanup token/);
  register(a, "z", {}, small);
  assert.throws(() => register(b, "z", {}, small), /capacity exhausted/);
  adapter.disposeOwner("a", 1); register(b, "z", {}, small);
  keydown(b.button); assert.equal(b.context.values.length, 1);
});

test("already handled keys stay untouched and application scope wins within the same owner", () => {
  const app = scope(); register(app, "Escape", { scope: "application", prevent: true });
  const local = { ...app, context: { ...app.context, request: { id: ++next, callback: "local" }, values: [] } };
  contexts.push(local.context); register(local, "Escape");
  const handled = new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, composed: true, cancelable: true });
  handled.preventDefault(); app.button.dispatchEvent(handled);
  assert.equal(app.context.values.length, 0); assert.equal(local.context.values.length, 0);
  keydown(app.button, "Escape");
  assert.equal(app.context.values.length, 1); assert.equal(local.context.values.length, 0);
});

test("static refs activate and deactivate scopes with branch lifetime and reactivate above older owners", () => {
  const graph = scope("graph"); register(graph);
  const form = scope("form"), other = scope("other");
  let dialog = null;
  form.context.resolveRef = name => name === "dialog" ? dialog : null;
  register(form, "Escape", { scope: "application", active_ref: "dialog", prevent: true });
  keydown(graph.button); assert.equal(graph.context.values.length, 1);
  dialog = document.createElement("section"); form.root.appendChild(dialog);
  adapter.reconcileOwner("form", 1);
  keydown(graph.button); assert.equal(graph.context.values.length, 1);
  keydown(graph.button, "Escape"); assert.equal(form.context.values.length, 1);
  register(other, "Escape", { scope: "application" });
  keydown(graph.button, "Escape"); assert.equal(other.context.values.length, 1);
  dialog.remove(); dialog = null; adapter.reconcileOwner("form", 1);
  dialog = document.createElement("section"); form.root.appendChild(dialog);
  // Key handling checks activation too, before a mutation observer can run.
  keydown(graph.button, "Escape"); assert.equal(form.context.values.length, 2);
  dialog.remove(); dialog = null;
  adapter.disposeOwner("other", 1);
  keydown(graph.button); assert.equal(graph.context.values.length, 2);
  adapter.disposeOwner("form", 1);
  const region = document.createElement("section"); form.root.appendChild(region);
  const button = document.createElement("button"); region.appendChild(button);
  form.context.resolveRef = () => region;
  register(form, "z", { active_ref: "region" });
  keydown(form.button); assert.equal(form.context.values.length, 2);
  keydown(button); assert.equal(form.context.values.length, 3);
});
