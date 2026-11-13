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
requires byte-identical file sets and SHA-256 hashes for both builds. A generic
capability membership check compares each adapter's initial membership with
the initial dependency closure of its declared Ruby packages, so unused
adapters stay out of the initial load and used adapters are present.

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

Measured 2026-11-12 on the repository toolchain:

| Set | Raw bytes | Gzip bytes | Files |
| --- | ---: | ---: | ---: |
| Core runtime | 416,678 | 139,457 | 3 |
| Minimal initial | 419,218 | 140,713 | 7 |
| Feature initial | 420,025 | 140,898 | 7 |
| Later feature load | 13,618 | 4,475 | 4 |
| Feature total | 433,643 | 145,373 | 11 |

The current baseline includes the opt-in routing contract and core storage
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

The fetch lifecycle work adds 3,616 raw bytes and 730 gzip bytes to the
previous routing/storage baseline. This measured growth is in `mochi-loader.js`:
request cancellation, latest-query-wins handling, mount-safe response delivery,
and JSON conversion for Ruby Hash request bodies. These browser fetch lifecycle
operations are currently implemented in the loader even when an app does not
call `Mochi.fetch`.

The route and storage contracts had previously added 7,031 raw bytes and 1,378
gzip bytes over the pre-route/storage baseline. Both changes belong to the core
runtime, not to either fixture's entry component or later feature load.

Core runtime:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-gvm.wasm` | 186,160 | 85,371 |
| `mochi-gvm.js` | 62,944 | 17,568 |
| `mochi-loader.js` | 167,574 | 36,518 |

Minimal initial:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `index.html` | 170 | 132 |
| `mochi-manifest.json` | 500 | 233 |
| `components/my-counter.chi` | 511 | 282 |
| `components/my-counter.json` | 1,359 | 609 |

Feature initial adds only manifest metadata:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-manifest.json` | 1,307 | 418 |

The feature manifest is 807 raw bytes and 185 gzip bytes larger than the
minimal manifest. This is capability metadata, not the adapter implementation.

Later feature load:

| File | Raw | Gzip |
| --- | ---: | ---: |
| `mochi-format.js` | 10,578 | 3,022 |
| `components/format-badge.chi` | 284 | 235 |
| `components/format-badge.json` | 662 | 359 |
| `components/ruby-*.chi` | 2,094 | 859 |

The exact Ruby package digest is checkout independent and is asserted by the
manifest audit.

## Ceilings

`references/payload_budgets.json` is the machine-readable source of truth.

- Raw ceilings equal the measured baseline. Any raw growth requires an
  explicit budget update and a stated semantic reason.
- Gzip ceilings allow the larger of 64 bytes or 1 percent of the baseline to
  absorb compressor implementation differences. This is not headroom for code
  growth.
- The script also rejects unexpected files, missing referenced files, duplicate
  package/resource files, and initial/later set overlap.
- An exclusion self-check injects the real `mochi-format.js` and an orphan
  stylesheet into a copied minimal bundle. The audit must reject both.

Update a budget only for an intentional artifact change. State whether the
cost belongs to the core runtime, entry component, or later feature load.
