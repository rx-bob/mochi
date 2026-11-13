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

Measured 2026-11-13 on the repository toolchain, after rebuilding compiler and
WASM from the current shared worktree:

| Set | Raw bytes | Gzip bytes | Files |
| --- | ---: | ---: | ---: |
| Core runtime | 492,590 | 159,379 | 3 |
| Minimal initial | 496,268 | 161,085 | 7 |
| Feature initial | 497,080 | 161,270 | 7 |
| Later feature load | 14,236 | 4,601 | 4 |
| Feature total | 511,316 | 165,871 | 11 |
| Network initial | 501,403 | 162,583 | 8 |
| Network total | 501,403 | 162,583 | 8 |

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

Core runtime (current measured artifacts):

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-gvm.wasm` | 212,593 | 95,768 |
| `mochi-gvm.js` | 63,170 | 17,609 |
| `mochi-loader.js` | 216,827 | 46,002 |

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
| `mochi-manifest.json` | 1,638 | 683 |
| `components/my-counter.chi` | 511 | 282 |
| `components/my-counter.json` | 1,359 | 609 |

The pre-slicing complete core was 489,545 / 157,958 raw / gzip bytes. Minimal
initial is 493,223 / 159,664; formatting feature initial is 494,035 / 159,849;
formatting feature total is 508,271 / 164,450; and network initial/total is
498,358 / 161,162. The E1.S2 increase documented above is included in the
current JSON budget.

Feature initial adds only manifest metadata:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-manifest.json` | 2,475 | 871 |

The feature manifest is 837 raw bytes and 188 gzip bytes larger than the
minimal manifest. This is capability metadata, not the adapter implementation.

Later feature load:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-format.js` | 11,196 | 3,148 |
| `components/format-badge.chi` | 284 | 235 |
| `components/format-badge.json` | 662 | 359 |
| `components/ruby-*.chi` | 2,094 | 859 |

The exact Ruby package digest is checkout independent and is asserted by the
manifest audit.

Network initial adds these files to core:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `index.html` | 176 | 135 |
| `mochi-manifest.json` | 1,960 | 764 |
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
