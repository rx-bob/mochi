# 14KB First Paint: Declarative Shadow DOM + Deferred Opal

## Problem

Mochi currently requires the browser to download and execute Opal (~3.6MB) before
any component content is visible. This means 3+ TCP roundtrips before the user sees
anything, regardless of app size.

The goal: **show the page after exactly 1 TCP roundtrip (~14KB)**.

## Core Insight

"Show the page" and "make the page interactive" are different things. They don't need
to happen at the same time.

Browsers natively support **Declarative Shadow DOM** (Chrome 111+, Safari 16.4+,
Firefox 123+). A `<template shadowrootmode="open">` element inside a custom element
tag causes the browser to attach a shadow root directly from HTML — no JavaScript
required.

```html
<my-counter>
  <template shadowrootmode="open">
    <button>-</button>
    <span>0</span>
    <button>+</button>
  </template>
</my-counter>
```

The browser renders this immediately on HTML parse. Opal never touches the critical
rendering path.

## Proposed Architecture

### Build Step Output (unchanged host, new artifact)

The Mochi compiler currently outputs:
- `runtime.js` — Opal base + signal/component runtime
- `bundle.js` — Opal-compiled Ruby components

It would additionally pre-render `index.html` with:
- Component initial states inlined as declarative shadow DOM
- `bundle.js` loaded with `defer` (already deferred by spec for `type="module"`, or
  explicitly with `defer` attribute)

### First Roundtrip (≤14KB)

```
index.html
├── <head> critical CSS (inline or same-origin preload)
└── <body>
    ├── <my-counter>
    │   └── <template shadowrootmode="open">  ← pre-rendered initial state
    │         <button>-</button><span>0</span><button>+</button>
    │       </template>
    ├── <item-list>
    │   └── <template shadowrootmode="open">  ← pre-rendered initial state
    │         <ul><li>...</li></ul>
    │       </template>
    └── <script src="bundle.js" defer></script>  ← does NOT block paint
```

Budget:
```
HTML + inlined initial shadow DOM:   ~8-10KB (gzipped)
Critical inline CSS:                  ~3-4KB
────────────────────────────────────────────
Total:                               ~11-14KB  ✓
```

Opal + bundle.js load after paint. Size irrelevant for first paint.

### Deferred Hydration

When `bundle.js` eventually loads and `customElements.define()` runs, the custom
element upgrade process finds the shadow root already attached (declarative shadow DOM
creates it before JS runs). The component constructor wires up:

- Event listeners
- Reactive bindings (signals → DOM node refs)
- Any state that diverged from initial (e.g. restored from localStorage)

This is hydration, not render-from-scratch. The user never sees a flash — the DOM is
already there.

## What the Compiler Needs to Do

### 1. Pre-render initial component HTML

At build time, Crystal already has:
- Every component's `def html` template
- Every component's `initialize` defaults

For components with **statically knowable initial state**, render the template to an
HTML string with initial values substituted. Emit this as the declarative shadow DOM
inside the component's tag in `index.html`.

### 2. Track which components are on which routes

The compiler needs to know which components appear on the initial page (or each route
for an SPA) so it knows which initial states to inline.

### 3. Mark `bundle.js` as deferred

Trivial — add `defer` to the script tag. Already harmless since custom elements
without a definition are just inert HTML until upgraded.

### 4. Hydration-aware component constructor

When the real component class loads and upgrades the element, it should detect that
a declarative shadow DOM already exists and skip the initial render. Wire up events
and signals onto the existing nodes.

Rough sketch:
```js
connectedCallback() {
  // shadow already exists from declarative shadow DOM — skip render
  if (this.shadowRoot && this.shadowRoot.childNodes.length > 0) {
    this._hydrate(this.shadowRoot);
  } else {
    this._mount(this.attachShadow({ mode: 'open' }));
  }
}
```

## The Statically Knowable Problem

Not all components have deterministic initial state at build time.

| Component type | Build-time renderable? |
|---|---|
| Counter starting at 0 | Yes |
| Static nav/layout | Yes |
| List from hardcoded data | Yes |
| Component reading from `localStorage` | No |
| Component fetching from an API | No |
| Component reading URL params | No |

For components whose initial state is runtime-dependent, the declarative shadow DOM
is omitted. The custom element tag is present in HTML but empty. That component shows
nothing until Opal loads and renders it — same as today, but isolated to those
specific components rather than the entire page.

For most UI components (layout, navigation, static content, components with hardcoded
defaults), initial state IS known at build time.

## What Does Not Change

- **Ruby stays arbitrary.** Opal is untouched. Users write the same Ruby.
- **Build tool stays build-time only.** No request-time server rendering. Crystal
  generates static files as before; it just also generates initial HTML.
- **Interactivity is unchanged.** Opal still handles all events, state, reactivity.
  It just no longer blocks first paint.
- **Bundle size is not reduced.** This solves first-paint latency, not download size.
  A separate effort (tree-shaking, lazy-loading Opal) could address download size.

## Epics

### Epic 1: Build-time initial state rendering

The compiler pre-renders component initial HTML to strings. For a given route, it
knows which component tags appear and renders their initial states.

Stories:
- Render a component's `def html` to an HTML string using initial `initialize` values
- Handle `{var}` substitution with default values in the rendered string
- Skip components whose initial state cannot be determined at build time (render them
  as empty tags)
- Handle nested components (a component's initial render may include child components)

### Epic 2: Declarative shadow DOM emission

The compiler writes the pre-rendered HTML into `index.html` as declarative shadow DOM.

Stories:
- For each component tag in the page, wrap its pre-rendered HTML in
  `<template shadowrootmode="open">`
- Insert this inside the custom element tag in `index.html`
- Ensure the emitted HTML is valid and well-formed

### Epic 3: Deferred bundle loading

Stories:
- Add `defer` to the `<script>` tag for `bundle.js` in emitted HTML
- Verify that `customElements.define` still runs correctly when deferred
- Ensure no race conditions between DSD upgrade and JS component definition

### Epic 4: Hydration-aware component constructor

Stories:
- In `MochiComponent` (or new engine equivalent), detect pre-existing shadow DOM
- If shadow DOM exists: hydrate (wire events/signals to existing nodes) rather than
  render from scratch
- If shadow DOM does not exist: render as before (fallback for runtime-state components)
- Ensure `mounted()` lifecycle fires correctly in both paths

### Epic 5: Route-aware pre-rendering for SPAs

For multi-route SPAs, the compiler knows the component tree for each route.

Stories:
- Pre-render the initial route's components into `index.html`
- For other routes, pre-render into separate HTML files or skip (TBD based on SPA
  routing architecture)

---

## Future Project: mruby WASM Runtime

> **This is not part of the current plan.** The DSD approach above is the target.
> The mruby track is a separate, future project to be revisited once the DSD
> implementation is stable and shipped. Do not conflate the two.

### What problem it solves

DSD solves first-paint — the user sees the page in one roundtrip. It does not reduce
time-to-interactive. Opal still loads after first paint: 3.6MB of JS to download,
parse, and execute. On slow connections or low-end devices, the page looks done but
nothing responds for several seconds.

mruby WASM would attack that second problem.

### Why mruby over Opal

| | Opal | mruby WASM |
|---|---|---|
| Runtime size | ~3.6MB JS | ~100-200KB WASM (gzipped) |
| Parse cost | High (JS parser) | Near-zero (pre-compiled binary) |
| Cache behaviour | Normal HTTP cache | Browser caches compiled WASM permanently |
| Component code | ~250KB Opal JS | ~10-30KB `.mrb` bytecode |
| DOM access | Native | Requires JS/WASM bridge |
| Ruby compatibility | High | Subset — no refinements, limited stdlib |

WASM cache behaviour is particularly valuable: browsers cache compiled WASM modules
independently of HTTP cache. The parse cost is paid exactly once across all visits.

### Architecture

mruby cannot call DOM APIs directly — every DOM op would cross the WASM/JS boundary,
which has real per-call overhead. The solution is to keep DOM operations entirely on
the JS side and only cross the bridge once per event to run Ruby logic:

```
user event
    ↓
JS event handler (thin)
    ↓
call into mruby WASM → run Ruby method → return new state values
    ↓
JS DOM updater → apply state to DOM nodes
```

The Data VM concept from this document maps directly onto that JS DOM updater role.
mruby produces state; the VM applies it. The bridge is crossed once per interaction,
not once per DOM node.

### Spike questions before committing

Three unknowns need answers before this is worth building:

1. **Size**: what is the actual gzipped size of mruby WASM with only the stdlib
   that Mochi components realistically use? Target is under 200KB.

2. **Bridge overhead**: what is the JS/WASM boundary cost for a realistic component
   interaction (e.g. button click → state update → 5 DOM mutations)? If it exceeds
   ~2ms it likely negates the gains.

3. **Ruby compat**: what percentage of real Mochi component Ruby breaks on mruby?
   The constrained subset (instance vars, methods, each/map, conditionals) is
   probably fine — but needs validating against the devground components.

### Combined end state (if spike goes well)

```
First roundtrip (~14KB):  HTML + DSD pre-rendered content   → page visible
After first paint:        ~200KB mruby WASM + ~20KB Data VM  → interactive
                          (both cached permanently)
```

vs. current:

```
First roundtrip:          blank HTML
After 3+ roundtrips:      3.85MB Opal + bundle              → visible + interactive
```

---

## Open Questions

1. **Nested components**: if `<parent-comp>` renders `<child-comp>` inside its
   shadow DOM, the declarative shadow DOM needs to include the child's declarative
   shadow DOM too. How deep does this go?

2. **CSS in shadow DOM**: components with `<style>` blocks in their templates — are
   those included in the pre-rendered DSD? They should be, to avoid FOUC.

3. **Hydration mismatch**: if runtime state differs from pre-rendered state (e.g.
   localStorage restores a counter to 5), there will be a visual flash when Opal
   loads and updates. Strategy for minimising this?

4. **SPA routing**: after the initial route, navigation renders new components
   client-side with no DSD. Only the first load benefits. That's fine — subsequent
   navigations are fast because Opal is already loaded and cached.
