# Payload budgets

These are artifact acceptance checks, not benchmarks. They build checked-in
fixtures with the real compiler, enumerate the generated files from the
compiler manifest, and fail when membership, determinism, or byte ceilings
change.

Run:

```sh
task build
ruby scripts/payload_check.rb
```

`task check` runs the same script. The script needs no browser, monitoring
service, or timing harness.

## Exact inputs

Fixtures:

- `compiler/spec/fixtures/payload/minimal` — one `MyCounter` entry component.
- `compiler/spec/fixtures/payload/feature` — the same entry component plus a
  later `FormatBadge` component that calls `MochiFormat`.
- `compiler/spec/fixtures/payload/network` — an entry `NetworkPanel` that calls
  `Mochi.fetch`, making the network adapter part of its initial load.

Every fixture is compiled twice in separate temporary roots. The script
requires byte-identical file sets and SHA-256 hashes for both builds. Every
fixture receives the same file-integrity and capability membership checks.
Fixture expectations independently require no capabilities in minimal,
formatting only in the later feature load, and network in the network entry
closure. The audit checks both adapters and their declared Ruby packages.
A negative check moves formatting into the entry closure and must fail.

The compiler copies the current runtime artifacts:

- `../mochi-gvm/dist/mochi-gvm.wasm`
- `../mochi-gvm/dist/mochi-gvm.js`
- `runtime/mochi-loader.js`
- `runtime/mochi-format.js` when the formatting capability is reachable
- `runtime/mochi-fetch.js` when the network capability is reachable

Compression uses Ruby `Zlib::GzipWriter` at level 9 with the gzip modification
time fixed to 1. Raw byte counts are file sizes.

The initial file set is derived from the generated manifest and the component
tags present in `index.html`. Later files are the referenced files outside that
initial dependency closure. This makes `components/format-badge.json`,
`components/format-badge.chi`, the formatting Ruby package, and
`mochi-format.js` later feature files for the feature fixture.

## Baselines

Measured 2026-11-14 on the repository toolchain, after rebuilding compiler and
WASM from the current shared worktree:

| Set | Raw bytes | Gzip bytes | Files |
| --- | ---: | ---: | ---: |
| Core runtime | 424,471 | 135,576 | 3 |
| Minimal initial | 428,149 | 137,281 | 7 |
| Feature initial | 428,961 | 137,468 | 7 |
| Later feature load | 15,281 | 4,821 | 4 |
| Feature total | 444,242 | 142,289 | 11 |
| Network initial | 433,284 | 138,779 | 8 |
| Network total | 433,284 | 138,779 | 8 |

### Trusted markup ranges (E6.S1)

The core loader grows **5,111 raw / 972 gzip bytes**. The new range handling
inserts trusted nodes at their authored positions, patches only the owned range,
and parses fragments in their actual HTML, SVG, or table context. This removes
the implicit layout element without replacing neighboring drafts, focus, or
component nodes. The compiler schema, WASM, JS glue, optional packages, and
adapters are unchanged. Core-containing ceilings increase by this measured
loader delta; later feature bytes and capacity defaults stay unchanged.

### Mount-owned timer validation (E4.S1)

The rebuilt core grows **1,823 raw / 647 gzip bytes** against the previous
baseline. WASM grows **1,210 / 536** for exact timer argument validation,
callback method lookup/arity checks, and mount-instance IDs on cancellation.
The loader grows **613 / 111** to enforce cancellation ownership and report
failed callback dispatches through the normal timer error path. The VM and
loader share the existing timer bridge; no timer adapter, Ruby package,
manifest entry, or capacity increase is added. This cost makes invalid timer
calls source-located and prevents one mount from canceling another mount's
timer. All core-containing ceilings increase by this measured delta only;
later optional feature bytes and default capacities are unchanged.

### Lifecycle source diagnostics (completion audit)

The loader adds **364 raw / 90 gzip bytes** to preserve the lifecycle caller
through failed-mount rollback and qualify helper method names by class. A
`MochiDownload#save` failure during `mounted` must identify `mounted`, not an
unrelated component `save` method. Runtime initializer/mounted collision tests
and real-browser startup failures cover this path. WASM, JS glue, optional
packages/adapters and default capacities are unchanged. The exact budgets above
include this measured diagnostic correction; the story deltas below are historical.

### Optional bounded downloads (E6.S3)

Core grows **3,049 raw / 964 gzip bytes** against E6.S2. WASM adds **865 / 421**
for a synchronous byte-view bridge; JS glue adds **990 / 284** for decoding
metadata and passing bounded views directly to the optional adapter. This
avoids JSON transport limits and preserves binary Strings while keeping user
activation. Loader adds **1,194 / 259** for live mount ownership, capability
limits, readiness before rendering controls, and class-qualified source mapping (helper names must not borrow an
unrelated component method's source). Default capacities remain unchanged.

The Blob/URL implementation stays optional: `mochi-download.js` is **3,961 raw /
1,596 gzip bytes**, and its Ruby package is **228 / 196**. Combined optional
code is **4,189 / 1,792**, excluding consumer code and manifest metadata.
Minimal apps omit both; the existing formatting feature-later set is unchanged.
Browser coverage delays the adapter response and proves export controls are
not rendered until it is ready. URLs have bounded, disposal-safe 30-second
leases; runtime tests verify byte/count limits, immediate failure cleanup,
and repeated reuse. See [the download contract](DOWNLOAD_CONTRACT.md).

### Optional clock and timestamp formatting (E6.S2)

Core grows **870 raw / 446 gzip bytes** against E6.S1. WASM is now
**216,643 raw / 98,256 gzip bytes**. Loader and JS glue remain unchanged.
The shared cost creates a validated Time value through existing state/GC
machinery and connects clock/timestamp formatting through the existing native
capability bridge. A narrow constructor keeps Time.at pure without introducing
general Ruby object construction or a new VM storage type. Capacity defaults,
memory limits, and lifecycle infrastructure are unchanged.

`mochi-time.js` is **1,219 raw / 585 gzip bytes**; the Time Ruby package is
**444 / 285**. Combined optional clock code: **1,663 / 870**, excluding consumer
code and manifest/descriptor metadata. Neither file enters unrelated apps.
The stateless adapter reads wall time only on request; it retains no timers,
callbacks, owners, or cache. Formatter loading is independent of clock loading.

Existing optional formatting gains the explicit Unix-seconds timestamp path:
**766 / 154** adapter bytes and **279 / 66** Ruby-package bytes. The formatting
feature's later download therefore grows **1,045 / 220**. All ceilings increase
only by these measured costs; no spare raw-byte headroom is added. See the
[timestamp contract](RUBY_SURFACE.md#optional-wall-clock-and-unix-timestamps).

### Optional JSON API and shared codec (E6.S1 historical delta)

Core grows **2,823 raw / 1,290 gzip bytes** against E5.S3. WASM is now
**215,773 raw / 97,810 gzip bytes**. The loader and glue are unchanged.
This is an explicit core decision: strict JSON runs directly against VM values
to preserve signed64 integers, reuse existing parsing and escaping, validate
UTF-8, and reject cycles/unsupported values within byte and depth limits.
The current VM is one WASM module, so these primitives remain in core even
when the small Ruby entry package is absent. No JavaScript JSON adapter,
numeric host round trip, capacity increase, or memory-profile change is added.

The **271 raw / 197 gzip byte** optional Ruby package is selected by top-level `require 'json'` or JSON
constant reachability; unrelated apps omit it. Package-graph and browser tests
enforce this boundary. Exact core-containing budgets increase only by the
measured delta; later feature load is unchanged. See the
[Ruby JSON contract](RUBY_SURFACE.md#optional-json).

### Optional owned shortcuts (E5.S3 historical delta)

Core grows **206 raw / 43 gzip bytes** against E5.S2. Loader is now
**227,841 raw / 48,374 gzip bytes**. The shared cost is a mount-guarded
composed-path scope lookup and the capability's capacity mapping. WASM, glue,
existing optional adapters, capacity defaults, and memory limits are unchanged.
All core-containing baselines increase by this exact delta.

`mochi-shortcuts.js` is **6,888 raw / 2,161 gzip bytes**; its Ruby package is
**391 raw / 280 gzip bytes**. Combined optional feature code is **7,279 / 2,441**,
excluding consumer component code and manifest/descriptor metadata. Both files
are absent from minimal applications and load once when a consuming component
mounts. Keyboard policies and registration tables remain in the optional
adapter. See [shortcut contracts](SHORTCUT_CONTRACT.md).

### Wheel input and owned listeners (E5.S2 historical delta)


Core grows **4,749 raw / 1,068 gzip bytes** against E5.S1. Loader is now
**227,635 raw / 48,331 gzip bytes**. This covers normalized raw wheel fields,
three fixed unit buckets per active target, frame coalescing, target ownership
checks, and actual-region non-passive listeners with branch/remount cleanup.
Binding these regions is necessary for reliable native scroll prevention in
Chromium and WebKit; a delegated shadow-root listener failed that regression.

WASM, glue, optional layout files, capacity defaults, and memory limits are
unchanged. Graph conversion/zoom methods live in its component bytecode. This
is an explicit shared event-layer cost; no optional adapter is made eager.
All baselines increase by the measured loader delta, with no extra headroom.
See [wheel contracts](WHEEL_CONTRACT.md).

### Optional layout (E5.S1 historical delta)


Shared loader support grows **1,241 raw / 211 gzip bytes** against E4.S3.
This pays for mount-guarded static-ref resolution, repeat notifications,
frame-phase completion, and generic adapter cleanup/reconciliation. The loader
is **222,886 raw / 47,263 gzip bytes**. WASM, glue, memory ceilings, and all
capacity defaults remain unchanged. The exact budgets include this core cost;
the formatting feature's later load is unchanged.

`MochiLayout` and `mochi-layout.js` are absent from the minimal bundle and load
only when a dependent component mounts. Their separate optional costs are
recorded in the E5.S1 evidence in `UI_FIXTURE_CONTRACTS.md`. The compiler graph
and browser tests enforce omission and lazy loading. See
[the layout contract](LAYOUT_CONTRACT.md) for ownership and coordinate rules.

### Capacity lifecycle diagnostics (E4.S3 historical delta)


Computed-entry allocation failure now retains the rejected method's source
context even before its VM frame exists. This adds **84 raw / 11 gzip bytes**
to WASM and core against E4.S2. WASM measures **212,950 raw / 96,520 gzip bytes**;
loader and glue are unchanged. The exact ceilings above include only this
measured change. Stress fixtures and assertions ship no application runtime
bytes. Default capacities, capacity fingerprint, memory maximum, and region
accounting are unchanged.

### Structured computed fixtures and persistent storage (E4.S2 historical delta)

The 480-record fixture reproduced a WASM backing-storage overrun before its
declared state limit. Persistent arenas and GC bookkeeping now have bounded
inline storage, initialized directly in their static destinations. Promotion
fills new collections without scanning published roots for every copied slot.
These correctness changes reduce core payload by **6,905 raw / 2,393 gzip bytes**
against E4.S1: WASM is **212,866 raw / 96,509 gzip bytes**. Loader and JS glue are
unchanged. Fixture projections and test counters add no production adapter.
The exact ceilings above are tightened to measured values.

The physical backing has a memory cost: on this toolchain, a fresh initialized
Node-hosted WASM grows to **80,084,992 bytes**, versus **66,453,504** before the
fix. Both remain under the unchanged 96 MiB maximum. Link-time initial memory
is **26,738,688 bytes**, including the static arenas; the build specifies a
4 MiB initial heap separately. These are linear-memory measurements, not RSS
or a claim that arbitrary data fits. The corrected profile accounts for 40
Goose regions and a minimum of **82,313,216 bytes**. All application arena
limits remain unchanged. See [capacity contracts](CAPACITY_CONTRACT.md).

### Explicit computed values (E4.S1 historical delta)

Core grows **7,484 raw / 3,236 gzip bytes** against E3.S3. This is an explicit
core cost for lazy per-instance caching, root-write invalidation, binding-mask
propagation, GC retention/disposal, and runtime purity/reentry guards. The VM
dispatch, state and collector seams must cooperate; they are core semantics.
Declarations and projection bodies remain application bytecode, emitted only
when used. There is no added host adapter, production counter or telemetry.
The browser counter exists only in a separately built temporary test runtime.

| Artifact | Before raw / gzip | After raw / gzip | Delta raw / gzip |
| --- | ---: | ---: | ---: |
| WASM | 212,593 / 95,768 | 219,771 / 98,902 | +7,178 / +3,134 |
| Loader | 221,339 / 46,950 | 221,645 / 47,052 | +306 / +102 |
| VM JS glue | 63,170 / 17,609 | 63,170 / 17,609 | 0 / 0 |

The loader delta maps failures during a computed flush to the authored method
instead of its triggering event handler. The three computed storage tables
raise the generated Goose region count from 47 to 50; the capacity fingerprint
and minimum-memory estimate now account for that storage. Application arena
limits and the 96 MiB maximum are unchanged. Default minimum-memory accounting
is 83,230,720 bytes. Small profiles may compile fewer temporary regions;
compiler specs verify their generated counts stay within the accounting bound.

The exact measured baselines above replace the previous ceilings, with no extra
raw headroom and unchanged gzip tolerance. Later formatting resources remain
14,236 raw / 4,601 gzip bytes. Repeated builds remain byte-identical, and the
existing optional-capability membership checks pass. The few-byte compressed
manifest changes reflect the new capacity fingerprint.

### Graph history and pointer fixture cost

UI-contract story E3.S3 adds **zero core runtime bytes** and changes no payload
baseline. Graph history and editing are component Ruby code. The existing
pointer adapter and its Ruby package load on demand when the graph mounts;
inspector-only rendering requests neither the adapter nor graph code. Browser
checks observe one pointer-adapter request across repeated graph mounts.
Capture-owner resolution in the Ruby test driver is test-only and ships no
browser application bytes. Runtime capacities remain unchanged.

Using the existing payload accounting with gzip level 9 / mtime 1 on a staged
shared UI project, the inspector entry is **509,550 raw / 164,547 gzip bytes**.
Replacing only the graph source with its E3.S2 version from commit
`b8f6123ebf55751b72138760864696186bc8a00b` under the same compiler gives **509,114 / 164,426 bytes**: the **436 raw / 121 gzip byte**
initial increase is dependency/capability manifest metadata, not eagerly loaded
graph code. The graph's later download is **28,970 raw / 7,747 gzip bytes**,
up from **13,695 / 3,590** for E3.S2. Its current files are:

| Graph-only file | Raw bytes | Gzip bytes |
| --- | ---: | ---: |
| Graph bytecode | 8,752 | 3,448 |
| Graph descriptor | 14,444 | 2,516 |
| Pointer Ruby package | 325 | 209 |
| Existing pointer adapter | 5,449 | 1,574 |

These are fixture measurements, not new framework ceilings. The unchanged
minimal/feature/network budget fixtures continue to enforce the core boundary.

### Native event identity cost

UI-contract story E3.S2 adds **203 raw / 49 gzip bytes** to the loader,
from 221,136 / 46,901 to 221,339 / 46,950. Native events expose explicit target
and bound-handler dataset snapshots through the existing filtered path.
Legacy target data remains compatible; typed child payloads are unchanged.
This is core event normalization and requires no optional adapter. The new
maps count toward the existing event envelope limit; capacities do not grow.
Graph/inspector selection remains component Ruby code. SVG test activation is
runner-only. WASM, JS glue, and optional downloads are unchanged. Baselines
increase by exactly the measured delta.

### SVG insertion contract cost

UI-contract story E3.S1 adds **1,578 raw / 327 gzip bytes** to the loader,
from 219,558 / 46,574 to 221,136 / 46,901. Complete patch snapshots resolve
compound SVG attributes before writing them; conditional branches initialize
scalar SVG attributes before insertion. The compiler defers ordinary SVG
attributes during parsing, extending the existing keyed-row contract, and
preserves canonical SVG attribute names. This is shared renderer correctness,
so the loader cost belongs in the core. Graph code ships only when requested.
WASM, JS glue, capacities, optional adapters, and later feature downloads are
unchanged. Baselines increase by exactly the measured loader delta.

### Boolean prop and form contract cost

UI-contract story E2.S4 adds **96 raw / 22 gzip bytes** to the loader,
from 219,462 / 46,552 to 219,558 / 46,574. Row attribute classification now
matches the exact binding slot, allowing a declared child prop such as
`required=false` beside a native input whose `required=false` removes the
attribute. The compiler resolves declared prop attributes after the component
inventory is known; it needs no eager child descriptors or runtime schema
lookup. Boolean typecheck adaptation and keyboard test operations are
build/test-only. WASM, JS glue, capacity defaults, and optional downloads are
unchanged. Baselines increase by exactly the measured loader delta.

### Bound event composition cost

UI-contract story E2.S3 adds **363 raw / 62 gzip bytes** to the loader,
from 219,099 / 46,490 to 219,462 / 46,552. Row templates retain property
slots and update bound input/select/checkbox properties through the existing
property writer. These shared DOM operations belong in the core. Ordered
setter/callback actions compile into one Ruby entrypoint per used event;
there is no browser action interpreter or new VM ABI. Generated wrappers ship
only in components using composed bindings. WASM, JS glue, optional modules,
capacity defaults, and later feature downloads are unchanged. Baselines rise
by exactly the measured loader delta, with no additional headroom. The failure
probe's larger scratch/event buffers and smaller state pool are test-only.

### Mixed structural fragment cost

UI-contract story E2.S1 adds **2,272 raw / 488 gzip bytes** to the loader,
from 216,827 / 46,002 to 219,099 / 46,490. Shared row/branch reconciliation
retains lexical event context, keyed descendants, insertion context, and
normal child disposal. Deferred SVG attribute slots prevent the browser from
parsing placeholders as numeric/path values. These are essential template and
DOM operations, so their shared implementation belongs in the core loader.
Only components using row conditionals receive their branch descriptors and
generated Ruby bytecode. WASM, JS glue, capabilities, capacity profiles, and
later feature downloads are unchanged. The budgets increase by exactly the
measured loader delta, with no additional headroom. Runner mount waiting is
test-only and adds no shipped bytes.

### Scoped helper constants and dispatch cost

UI-contract story E1.S3 adds **1,038 raw / 534 gzip bytes** to WASM, from
211,555 / 95,234 to 212,593 / 95,768. Constants retain their owning module;
method and block frames retain lexical scope; qualified constant reads execute
in the VM; and missing explicit helper calls name the actual receiver.
These are essential Ruby semantics, so the measured cost belongs to the core.
The VM stores an owner identifier per constant/method/frame; no global
capacity is raised. Helper implementations remain dependency-selected Ruby
bytecode. The loader, JS glue, and later optional feature payload are unchanged.
The repaired compiler verifier runs only at build time, and failure-only debug
compilation adds no debug section to successful bundles. Budgets increase by
exactly the measured core delta.

### Array indexing and slicing cost


UI-contract story E1.S2 adds **2,007 raw / 887 gzip bytes** to WASM, from
209,548 / 94,347 to 211,555 / 95,234. The shared checked dispatch handles
single-index and two-argument calls consistently; bounded shallow copying
reports precise capacity failures without publishing truncated results.
Array indexing/slicing belongs to essential Ruby VM semantics and works in
all component execution contexts, so this cost enters every app's core.
No package, adapter, source-sized buffer, or capacity increase is added.
The loader, JS glue, entry components, and later feature downloads are
unchanged. The budgets increase by exactly the measured delta, with no
additional headroom. The table above includes this change.

### Pointer, drag, and file capability cost


E8.S1–E9.S4 add 26,108 raw / 6,005 gzip bytes to the core runtime compared
with the previous enforced baseline. The measured change is 7,385 / 2,733
bytes in `mochi-gvm.wasm` and 18,723 / 3,272 bytes in `mochi-loader.js`;
`mochi-gvm.js` is unchanged. The loader cost covers native event dispatch,
pointer-move coalescing and capture cleanup, drag-event command routing, file
metadata capture, and mount-owned file cleanup. These operations coordinate
the VM event bridge and component lifecycle, so their shared dispatch remains
in the core loader. The pointer, drag, and files implementations and their Ruby
packages are still optional capability artifacts and are absent from apps that
do not request them.

The native file contract also flushes pending synchronous host commands before
queuing an asynchronous read. This preserves open/read ordering and adds 2,613
raw / 1,257 gzip bytes to the rebuilt VM and loader artifacts. The complete
core now measures 489,545 / 157,958 raw / gzip bytes, a 6.3% raw and 4.9%
compressed increase over the prior 460,558 / 150,621 baseline. The new ceilings
account for this measured browser-contract work; they do not add unmeasured
headroom.

Event argument expressions add a further 266 raw / 75 gzip bytes to the
loader. They are evaluated by the VM and cached for dispatch, but have no DOM
target; the loader retains their descriptor without trying to bind it to the
event element.

### Intentional budget update

The previous recorded core ceiling was 416,678 raw / 139,457 gzip bytes.
The current core grows by 39,914 raw / 9,632 gzip bytes. This refresh includes
the already implemented capacity, callback, global-event, and numeric contracts
in the shared worktree; it is not all new E5.S3 code:

| Core artifact | Previous raw / gzip | Current raw / gzip | Raw / gzip delta |
| --- | ---: | ---: | ---: |
| WASM | 186,160 / 85,371 | 195,703 / 88,833 | +9,543 / +3,462 |
| JS glue | 62,944 / 17,568 | 63,170 / 17,609 | +226 / +41 |
| Loader | 167,574 / 36,518 | 197,719 / 42,647 | +30,145 / +6,129 |

The numeric rounding additions account for 145 raw / 78 gzip WASM bytes over
the previously measured shared-worktree artifact. That increment handles
binary64 half ties and subnormal negative-precision floor/ceil correctly, and
distinguishes finite signed-64 conversion overflow from non-finite Float
errors. The bounded operations stay in numeric VM dispatch; they add no
optional package or formatting adapter.

E4.S1 correctness refinements add 1,022 raw / 488 gzip bytes over the preceding
455,570 / 148,601 core snapshot. WASM changes from 194,894 / 88,428 to
195,703 / 88,833 (+809 / +405) for bounded, lossless event-payload validation
and Ruby statement ordering across native publications and Goose subscription
commands. The loader changes from 197,506 / 42,564 to 197,719 / 42,647
(+213 / +83) to retain pending subscriptions until ready and renew reused VM
instance ownership. These checks share the existing global-event bridge;
no event helper package, adapter, or new buffer is loaded by unused apps.
Entry metadata and later capability artifacts are unchanged.

The VM now reports named capacity failures and rejects incomplete bridge
output, publishes compiled profile identity, supports explicit global-event
subscriptions, and includes bounded numeric rounding/precision operations.
The glue exposes the corresponding bridge exports. The loader validates
profile identity and adapter limits, drops failed callback outboxes, and owns
explicit event subscriptions, bounded queues, reentrant delivery, and mount
cleanup. Those shared bridge/lifetime rules belong in core. The optional
formatting and network implementations still remain outside unused entry
closures.

The E5.S3 loader validation alone changed its then-current loader from
196,635 → 197,506 raw bytes and 42,312 → 42,564 gzip bytes: +871 / +252.
It rejects oversized tables, JSON envelope expansion (including metadata),
and concurrent response reservations before an adapter becomes ready.

The minimal manifest grows from 500 / 233 to 1,638 / 683 bytes for the normalized
compiled capacity profile and fingerprint. Feature-only metadata adds a further
837 / 188 bytes over minimal. The later formatting adapter grows by 618 / 126
bytes to enforce its build-selected cache limit without a runtime default;
its Ruby package and component artifacts are unchanged. Network now has its
own exact raw/gzip gates instead of escaping byte accounting.

The preceding baseline included the opt-in routing contract and core storage
subscriptions. The loader owns one structured route state, push/replace history,
explicit route subscribers, and stale-navigation guards. The VM adds
`route_info`, `replace_route`, and `route_subscribe` builtins plus the
`_mochi_set_route_info` export. Route matching itself stays in optional
`AppRouter` Ruby bytecode, so the minimal and feature fixtures do not load a
router package.

Storage stays in the core because `storage_get`, `storage_set`, and
`storage_remove` were already VM builtins. The subscription addition owns one
subscriber map, one initial delivery, same-tab effective-change notification,
cross-tab `storage` event handling, VM synchronization on removal, and unmount
cleanup. The VM adds `storage_subscribe` and the `_mochi_remove_storage` export.
The optional `MochiStore` Ruby battery is emitted only when an application
mentions it, so neither payload fixture loads it.

Explicit global Ruby events use the core loader and VM bridge because they
share the existing `Mochi.emit` host path. The loader owns FIFO ordering,
subscriber snapshots, queue limits, and disposal; no optional Ruby helper
package is added to an unused application's load. This is unavoidable core
cost for preventing accidental broadcast and unbounded callback recursion.
The refreshed raw and gzip ceilings include this loader/bridge code.

The fetch lifecycle work adds 3,616 raw bytes and 730 gzip bytes to the
previous routing/storage baseline. This measured growth is in `mochi-loader.js`:
request cancellation, latest-query-wins handling, mount-safe response delivery,
and JSON conversion for Ruby Hash request bodies. These browser fetch lifecycle
operations are currently implemented in the loader even when an app does not
call `Mochi.fetch`.

The route and storage contracts had previously added 7,031 raw bytes and 1,378
gzip bytes over the pre-route/storage baseline. Both changes belong to the core
runtime, not to either fixture's entry component or later feature load.

### Rebuilt GVM runtime and bytecode compatibility (E2.S3)

The GVM WASM and JS were rebuilt from current runtime source before browser
validation. At that stage, core artifacts measured **415,706 raw / 133,115 gzip bytes**,
down from the previous recorded **511,067 / 165,293**. This is a reduction of
**95,361 raw / 32,178 gzip bytes** across WASM, JS glue, and loader. WASM
shrinks by **40,556 / 18,080**, JS glue by **55,502 / 14,262**, while loader
changes by **+697 / +164**. These exact artifact sizes replace the old ceilings;
gzip tolerance remains unchanged.

The rebuilt runtime executes mrbc's extended fallback method definitions.
Development install records already bind compiler, WASM, JS glue, and capacity
profile by SHA-256, so no identity schema or compatibility metadata change was
needed. New installs capture the matching artifacts, and stale or explicitly
incompatible paths continue to fail before compilation. The 255-method encoding
cliff is removed; fixed method-table, bytecode, and other capacity limits remain
documented in [fixed VM capacities](../docs/fixed-capacities.md). Debug tables
remain excluded from shipped `.chi` files.

### Canonical Ruby type inspection (E3.S1)

Canonical class identities and `Object#is_a?` checks add **498 raw / 397 gzip
bytes** to the core runtime, all in WASM; JS glue and loader are unchanged.
The predicate checks immediate and boxed numeric values, scratch and state
collections, strings, symbols, booleans, nil, and custom class ancestry without
wrapping values. The payload budgets below include this measured growth.

### Bounded Array#unshift (E3.S2)

Array prepending adds **1,333 raw / 445 gzip bytes** to the core runtime, all in
WASM. The implementation prepends linked slots in reverse argument order,
preserving receiver and element identities without copying the existing array.
Capacity failures use the existing scratch/state error paths; the budget below
includes this measured growth.

Core runtime (current measured artifacts):

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-gvm.wasm` | 179,993 | 81,975 |
| `mochi-gvm.js` | 8,658 | 3,631 |
| `mochi-loader.js` | 235,820 | 49,970 |

The pre-slicing VM build was 3,966 raw / 1,532 gzip bytes above its previous
recorded core baseline. The shared update includes bounded aggregate block
dispatch and string comparison needed by `Array#sum`, `min`, and `max`, along
with the concurrent event-delivery work in the checkout, so that combined
increment cannot be assigned to E6.S2 alone. The aggregate Ruby methods live
in an optional package and are excluded from apps that do not call them; the
core cost supplies one-pass block execution, checked numeric accumulation, and
Ruby ordering for Strings without adding a general Enumerable runtime.

Minimal initial (current measured artifacts):

| File | Raw | Gzip |
| --- | ---: | ---: |
| `index.html` | 170 | 132 |
| `mochi-manifest.json` | 1,638 | 682 |
| `components/my-counter.chi` | 511 | 282 |
| `components/my-counter.json` | 1,359 | 609 |

Minimal initial is 428,149 / 137,281; formatting feature initial is 428,961 /
137,468; formatting feature total is 444,242 / 142,289; and network initial /
total is 433,284 / 138,779. The checked-in JSON budget matches these measured
artifacts.

Feature initial adds only manifest metadata:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-manifest.json` | 2,450 | 869 |

The feature manifest is 812 raw bytes and 187 gzip bytes larger than the
minimal manifest. This is capability metadata, not the adapter implementation.

Later feature load:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-format.js` | 11,962 | 3,302 |
| `components/format-badge.chi` | 284 | 235 |
| `components/format-badge.json` | 662 | 359 |
| `components/ruby-*.chi` | 2,373 | 925 |

The exact Ruby package digest is checkout independent and is asserted by the
manifest audit.

Network initial adds these files to core:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `index.html` | 176 | 135 |
| `mochi-manifest.json` | 1,960 | 763 |
| `components/network-panel.chi` | 418 | 287 |
| `components/network-panel.json` | 633 | 343 |
| `mochi-fetch.js` | 5,626 | 1,675 |

## Ceilings

`references/payload_budgets.json` is the machine-readable source of truth.

- Raw ceilings equal the measured baseline. Any raw growth requires an
  explicit budget update and a stated semantic reason.
- Gzip ceilings allow the larger of 64 bytes or 1 percent of the baseline to
  absorb compressor implementation differences. This is not headroom for code
  growth.
- The script also rejects unexpected files, missing referenced files, duplicate
  package/resource files, and initial/later set overlap.
- Exclusion self-checks inject the real formatting/network adapters and an
  orphan stylesheet into copied minimal bundles. The audit must reject each.

Update a budget only for an intentional artifact change. State whether the
cost belongs to the core runtime, entry component, or later feature load.
