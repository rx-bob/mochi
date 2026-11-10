# Tiered Kernel Architecture

**Status:** Exploratory / deferred
**Author:** Engineering Decision Record
**Date:** 2026-05-15

---

## Problem Statement

MRI Ruby compiled to WASM with aggressive stripping (`--with-out-ext=...`, `-Oz`,
`wasm-opt`, dead-code elimination) still yields binaries in the **1.5–2.5 MB gzip**
range. The product originally targeted **800 KB gzip**, a threshold that is
architecturally incompatible with MRI's core VM, method dispatch table, GC, and
standard object model.

Two desires are in tension:

1. **Sub-800 KB initial load** — for fast first paint over mobile networks.
2. **Full gem support** — developers must be able to `require 'json'`,
   `require 'csv'`, etc., as they do on MRI.

The tiered kernel approach attempts to reconcile these by splitting the runtime
into a small core kernel and lazily-loaded bytecode modules.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Browser (first request)                                     │
│                                                             │
│  HTML shell ............ ~14 KB                             │
│  bootstrapper_v2.js .... ~8 KB                              │
│  mochi-kernel.wasm ..... ~500 KB gzip (tier 0)              │
│                                                             │
│  On first `require 'json'`                                  │
│    └── fetch /stdlib/json.iseq (~12 KB gzip)                │
│        └── mochi_load_iseq(wasmMemory, ptr, len)            │
│                                                             │
│  On first `require 'csv'`                                   │
│    └── fetch /stdlib/csv.iseq  (~18 KB gzip)                │
│        └── mochi_load_iseq(...)                             │
└─────────────────────────────────────────────────────────────┘
```

### Tier 0: Core Kernel WASM

A **custom-built MRI** containing only the primitives needed to interpret
pre-compiled ISEQ bytecode:

| Included | Purpose |
|----------|---------|
| VM (`insns.def`, `vm_eval.c`) | Execute ISEQ opcodes |
| Core classes (`String`, `Array`, `Hash`, `Numeric`, `Symbol`, `NilClass`, `TrueClass`, `FalseClass`, `Object`, `Class`, `Module`) | Every Ruby program needs these |
| `require` (C-level, `load.c` stripped) | Resolve and load `.iseq` chunks |
| GC (`gc.c`, simplified) | Object lifecycle |
| Method dispatch (`vm_method.c`, `eval.c` subset) | `#send`, `#respond_to?` |
| Exception model (`error.c`, `eval_error.c`) | `begin/rescue` |
| `Fiber` (not `Thread`) | Single-threaded async event loop |

| **Excluded** | Savings |
|--------------|---------|
| Parser (`parse.y`, `ripper`) | ~200 KB raw — `eval` and `-e` gone |
| `ObjectSpace` | ~30 KB raw |
| Full backtrace / `TracePoint` | ~50 KB raw |
| `Marshal` | ~40 KB raw |
| Full `Regexp` engine (Onigmo) | ~150 KB raw — replace with minimal or JS bridge |
| `File`/`Dir`/`IO` (beyond memory streams) | ~80 KB raw — WASM has no real filesystem |
| `Time`/`Date` | ~60 KB raw — gemify later |
| `JSON` C extension | ~40 KB raw — pure-Ruby gem loads as ISEQ |
| `Math` / `Complex` / `Rational` (C impls) | ~40 KB raw — pure-Ruby fallbacks or gemify |

**Estimated size:** ~1.0 MB raw → **~350–500 KB gzip** with
`-Oz`, `--strip-debug`, `--dce`, Brotli.

### Tier 1: Standard-Library ISEQ Chunks

Compiled at Mochi build time from MRI's `lib/` and common gems. Each is a
self-contained `.iseq` file with its own dependency graph.

| Chunk | Size (gzip est.) | Notes |
|-------|-----------------|-------|
| `json` | ~12 KB | Already pure Ruby in MRI; no C ext |
| `csv` | ~18 KB | Pure Ruby |
| `set` | ~4 KB | Pure Ruby |
| `pathname` | ~8 KB | Pure Ruby |
| `uri` | ~6 KB | Pure Ruby |
| `base64` | ~2 KB | Pure Ruby |
| `delegate` | ~3 KB | Pure Ruby |
| `observer` | ~2 KB | Pure Ruby |
| `pp` | ~8 KB | Pure Ruby, depends on `prettyprint` |
| `erb` | ~10 KB | **Will not work** — `ERB` calls `eval` with strings, which needs the parser. Tiered kernel has no parser. |

**Delivery:** HTTP lazy-load via `fetch()`. The ISEQ format is
architecture-independent and small.

### Tier 2: Application `.mrb` / `.yiseq` Components

User's own components are pre-compiled at Mochi build time into `.yiseq`
(bytecode + metadata) and loaded the same way as stdlib chunks.

---

## Tree Shaking at the ISEQ / Stdlib Level

Because Tier 1 is delivered as discrete ISEQ chunks, we can tree-shake
*across chunks* using static analysis at build time.

### Current MRI Approach (No Tree Shaking)

MRI's `require` is dynamic:

```ruby
require 'json'   # runtime lookup in $LOAD_PATH
```

There is no dead-code elimination of stdlib because everything lives in one
WASM binary and is linked at compile time.

### Tiered Tree-Shaking Approach

1. **Static require graph extraction**
   Parse all `.rb` files in the app + gems with a lightweight parser
   (Ruby Prism, not MRI's `parse.y`) to build a `require` dependency graph.

2. **Reachability analysis**
   Start from `app.rb` (entry point). Mark all `require`d files as reachable.
   Recurse. Unreachable files are omitted from the build output.

   ```ruby
   # app/counter.rb
   require 'json'       # reachable
   require 'csv'        # reachable (counter.rb uses it)
   require 'pp'         # unreachable (no path from entry)
   ```

3. **Symbol-level shaking inside ISEQ**
   Each ISEQ chunk contains `iseq` + `id_table` (symbol table) +
   `catch_table`. We can strip:
   - Unused method definitions (`def unused_helper; end` — no call site in
     reachable graph)
   - Unused class / module definitions
   - Dead `catch_table` entries for exceptions never raised

   This is similar to what `wasm-opt --dce` does at the WASM level, but
   applied at the Ruby bytecode level where we have semantic knowledge.

4. **Chunk deduplication**
   If two components `require 'json'` and `require 'json/pure'`, resolve to
   a single chunk. Use content-hash naming:
   `/stdlib/json-a3f7c2.isq.gz`

5. **Build output layout**
   ```
   build/
   ├── mochi-kernel.wasm          # ~500 KB gzip
   ├── mochi-kernel.wasm.br
   ├── stdlib/
   │   ├── json-a3f7c2.isq.gz
   │   ├── csv-81e2b4.isq.gz
   │   └── set-44d91c.isq.gz
   └── app/
       ├── counter-9f2e11.isq.gz
       └── router-b8c401.isq.gz
   ```

### Why Tree Shaking Works Better Here

- **Iseq is high-level:** We know `def`, `class`, `module` boundaries.
- **No dynamic `load`:** We disable `load` and `eval` in the kernel, making
  `require` the only way to pull in code. The graph is fully static.
- **No C-extensions in stdlib chunks:** Pure Ruby only. C extensions are
  either in the kernel (core classes) or unsupported (nokogiri, pg).

---

## Downsides & Risks

| Risk | Mitigation |
|------|-----------|
| **Parser removed → no `eval`, no ERB** | Document. Provide `Mochi::Template` (static HTML strings + interpolation) as replacement. |
| **Kernel size still > 500 KB?** | Prototype build required. If kernel alone is > 600 KB gzip, revisit (mruby tiered? further stripping?). |
| **HTTP waterfall** | `modulepreload` in HTML shell for known dependencies. Bundle predicted chunks into compound `.isq` files. |
| **Gems with dynamic `require`** | `autoload` fails. Gems that do `autoload :Foo, 'foo'` need static rewriting at build time. |
| **Debugging** | No `caller_locations`, no `TracePoint`. Error messages show VM PC + ISEQ filename only. Source maps needed. |
| **Regexp** | If we strip Onigmo, `Regexp.new('...')` fails. Option A: minimal POSIX regex engine in kernel. Option B: regex pre-compiled at build time, no runtime compilation. |
| **RubyGems itself** | `require 'rubygems'` needs the gem resolver, `Gem.path`, etc. — all filesystem-based. In WASM, we replace RubyGems with a static resolution table built at compile time. |

---

## Open Questions

1. Can we build a "kernel-only" MRI that passes `make test` for the subset
   of tests that exercise core classes + VM? What breaks?
2. What is the *actual* size of the smallest MRI WASM that can execute
   `puts [1,2,3].map { |x| x + 1 }.join`? We need a real measurement.
3. How much of the standard library is re-implementable in pure Ruby vs.
   needing C-API fallback functions in the kernel?
4. Is `Fiber` sufficient for the Mochi event loop, or do we need a custom
   scheduler?
5. Can we generate source maps from ISEQ back to original Ruby `.rb` files
   for DevTools debugging?

---

## Decision

**Deferred.** For now, we keep MRI as the single WASM runtime, raise the gzip
budget to **2 MB**, and accept that full gem support requires the full VM.
The tiered kernel is documented here as the path to sub-500 KB if / when the
product requirement hardens.

**Trigger to revisit:** A stakeholder or customer actively blocks adoption due
to first-load size, and 2 MB over HTTP/2 + caching is insufficient.
