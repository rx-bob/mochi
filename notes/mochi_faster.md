Takeaways:

  - Most single-operation benchmarks (create, replace, update, swap, remove, clear) land in the 23–30ms range — very consistent
  - Select row is the fastest (~23ms) since it's just a DOM class toggle with no re-render
  - Create 10,000 rows scales ~8.3× relative to 1,000, which is close to linear — good sign
  - Append 1,000 (47ms) is slower than create 1,000 (29ms) because it builds on top of 1,000 existing rows
  - The ~25ms floor on most operations is largely framework overhead (Opal + component lifecycle), not DOM operations themselves

  For reference, top-tier frameworks (Svelte, SolidJS) typically hit under 10ms for create/replace on the official Krausest harness. So there's meaningful
  overhead to chase down if you want to close that gap.

✻ Worked for 1m 16s

❯ how could we address the framework overhead?

⏺ Let me look at a few key areas before giving a diagnosis:

⏺ Searched for 3 patterns, read 2 files (ctrl+o to expand)

⏺ Now I have a clear picture. Here are the bottlenecks, ranked by impact:

  ---
  1. 1000 individual insertBefore calls into the live DOM (~biggest win)

  _reconcileEachBlock calls insertBefore once per new item inside the loop. Every insertion into a live document can trigger style recalculation. For a full
   create/replace, we should collect consecutive new nodes into a single DocumentFragment and do one insertion. The new engine's updateEach already does
  this correctly — the legacy reconciler doesn't.

  ---
  2. Key extraction going through Opal × N items

  getEachLoopKey does this.rubyComp.$__mochi_each_0_key(item, index) — an Opal method call — for every item on every reconcile. The generated Ruby key
  method (each_method_generator.cr:38) is just a backtick that checks item.id. That's 1000 Opal dispatch round-trips → Ruby → backtick → back to JS per
  render. The fix: generate the key logic as a pure JS closure stored on the component at init time, bypassing Opal entirely.

  ---
  3. _substituteItemVars runs TreeWalker + regex × N items

  For 1000 rows, that's ~7,000 TreeWalker iterations and regex matches. The long-term fix is to compile {each} templates into factory functions at transpile
   time — e.g. the compiler emits:

  _createEach_0(item, index) {
    const div = document.createElement('div');
    div.className = 'row-item';
    div.dataset.testid = 'row';
    // ... directly assign item.id, item.label
    return [div];
  }

  This eliminates cloneNode + TreeWalker + regex entirely, replacing them with direct property assignment. It's what SolidJS and Svelte do.

  ---
  4. Opal items retrieval (minor)

  evaluateEachLoop calls $__mochi_each_0_items() which Opal dispatches to Ruby which just returns @rows. One call per render so it's small, but a JS-side
  cache of the array reference would eliminate it.

  ---
  Realistic impact estimates

  ┌────────────────────────────┬────────────────────────┬───────────────────────────┐
  │           Change           │         Effort         │       Expected gain       │
  ├────────────────────────────┼────────────────────────┼───────────────────────────┤
  │ Batch insertions           │ Low                    │ ~30–40% on create/replace │
  ├────────────────────────────┼────────────────────────┼───────────────────────────┤
  │ Pure-JS key closure        │ Medium                 │ ~10–15%                   │
  ├────────────────────────────┼────────────────────────┼───────────────────────────┤
  │ Template factory functions │ High (compiler change) │ ~20–30%                   │
  ├────────────────────────────┼────────────────────────┼───────────────────────────┤
  │ All three combined         │ —                      │ ~29ms → ~10–12ms          │
  └────────────────────────────┴────────────────────────┴───────────────────────────┘

  Getting below ~5ms (SolidJS/Svelte territory) would require a more fundamental architectural change — fine-grained reactivity that doesn't reconcile whole
   lists but directly updates only the specific text nodes that changed.

   