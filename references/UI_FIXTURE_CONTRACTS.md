# UI fixture contracts: 2026-11-13 feedback batch

E1.S1 establishes a standalone inspector and records current behavior. It does **not** close the later compiler, VM, or browser capability stories. All results below are Mochi-owned probes; no application checkout is needed to compile or run them.

The source reports are the twelve files in `/Users/bob/repos/sencha/feedback/`, discovered during implementation. The plan calls them Cowboy feedback; their filenames and contents identify this batch. The seventeen entries in [FEEDBACK_CONTRACTS.md](FEEDBACK_CONTRACTS.md) are an older, independently numbered inventory. For example, this batch's `09-missing-platform-apis.md` is unrelated to that inventory's `009 Root-level conditional`. Neither inventory supersedes the other.

## Runnable baseline

[InspectorRoot.rb](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb) generates 48 deterministic records, each with a stable string ID, severity, message, and nested source/sequence details. It renders 12 records per page, filters by a literal message substring, clamps page bounds including empty results, and retains selection by ID. Records remain hashes throughout. It uses no service, external asset, app-authored JavaScript, or optional browser capability.

The E1.S1 baseline used a bounded scalar-index loop for page extraction. E1.S2 now uses `matches.slice(@page * 12, 12)` and verifies first, middle, last, filtered, and empty pages. E1.S3 moves generation into the helper module; E4.S1/E4.S2 own computed projections. These stages are explicit, not claims that the missing facilities are already supported.

[inspector_test.rb](../e2e/fixtures/ui_contracts/test/inspector_test.rb) is authored in Mochi's existing Ruby browser DSL. It checks all twelve first-page IDs/messages/severities, nested details, pagination, literal filtering, empty results, recovery, and stable selection. The framework test additionally counts actual DOM rows rather than trusting the fixture's displayed count.

From the Mochi repository root:

```sh
compiler/mochi test -i e2e/fixtures/ui_contracts --browsers=chromium,firefox,webkit
cd e2e
npx playwright test tests/gvm_ui_contracts.spec.ts --reporter=line,html
```

The shared [framework helper](../e2e/tests/framework_helpers.ts) copies projects, compiles, serves, and cleans up temporary directories. The inspector page can also be compiled normally with `compiler/mochi -i e2e/fixtures/ui_contracts -o <temporary-output-directory>`. Probes live outside its `lib/` tree so an intentionally failing probe cannot prevent the baseline build.

## Evidence rules

The [probe sources](../e2e/fixtures/ui_contracts/probes) retain the reported constructs with small local data. The [evidence suite](../e2e/tests/gvm_ui_contracts.spec.ts) distinguishes:

- **supported-in-isolation**: the stated minimal construct works; larger combinations remain unproven.
- **reproduced-defect**: the probe demonstrates a mismatch with the expected contract.
- **intentional-contract**: an existing bounded or language contract explains the result.
- **unresolved**: the original failure or broader capability has not been established by the probe.

Evidence tests assert precise current diagnostics or values. They are not skipped, expected-failure wrappers, or acceptance claims for later stories. Compiler failures require a nonzero exit and authored source location. Runtime failures require the named mount error and exactly one matching `mochi:error`; unrelated browser errors fail. On repair, replace the observed-failure assertion with the expected behavior below and update this inventory. Do not preserve an obsolete failure expectation or mark the test skipped.

The HTML test report contains `artifact-identity` attachments: SHA-256 hashes of compiler, probe source, every emitted bundle file (including descriptors, `.chi`, loader and WASM), and the complete generated manifest/capacity profile. Compiler and mount diagnostics are attached separately. Console capture begins before navigation, including SVG insertion. Browser silence alone does not prove correct transient SVG attributes.

## Report dispositions

Probe names below are directory names under `e2e/fixtures/ui_contracts/probes/` and match the test titles.

| Report filename / topic | Expected behavior | Observed evidence and disposition | Owner |
| --- | --- | --- | --- |
| `01-block-conditionals-and-loops.md` | Block `if` inside table rows, `each` inside `if`, and nested `each` preserve lexical scope and structure. | **reproduced-defect:** `01-if-in-each` rejects `if row['visible']` as an invalid Ruby expression, with source location. **supported-in-isolation:** `01-each-in-if` renders Alpha and `01-nested-each` renders Group/Alpha. The originally reported context mismatch and more complex combinations remain **unresolved**, not fixed. | E2.S1 |
| `02-array-slice-and-brackets.md` | `[1,2,3,4][1,2]` and `.slice(1,2)` return a fresh `[2,3]`. | **supported:** both probes now return a fresh two-element array containing `2,3`. `02-array-contexts` verifies Ruby boundaries, initialization/helper/handler/template parity, shallow identity, source-located errors, and slot exhaustion/recovery. Original `.to_s` expressions remain in the probes: Array text rendering still returns empty and is a separate unresolved surface, not a slicing failure. | E1.S2; history acceptance E3.S3 |
| `03-qualified-constants.md` | `RecordData::BASE` and `RecordData.base_ms` return `1794571200000` in component contexts. | **reproduced-defect:** `03-constant` fails in `initialize` with `bad opcode`. **supported-in-isolation:** `03-singleton` returns the correct value from the same helper module. The reported singleton receiver failure in the larger component remains **unresolved**; initialization does not prove handler/template parity. | E1.S3 |
| `04-scratch-capacity.md` | Structured local data work either completes correctly or reports the actual configured resource; later valid work recovers. | **supported-in-isolation:** `04-structured-records` mounts 480 hashes with nested attribute arrays; `04-concatenation` builds 360 lines / 24,370 bytes; `04-repeated-split` evaluates 480-line splits in 20 bindings. No exhaustion occurs for these inputs. Original richer object/byte exhaustion and repeated-update/recovery behavior remain **unresolved**. Configurability is an existing, tested **intentional-contract**. | E4.S1–E4.S3 |
| `05-template-attribute-quoting.md` | Double-quoted Ruby hash keys work inside double-quoted HTML attributes and conditional classes. | **reproduced-defect:** `05-attribute-quotes` rejects `aria-label="{@modal["title"]}"` as an unclosed placeholder; independent `05-conditional-quotes` rejects `class="{if @node["ghost"]}ghost{end}"` with `stray '}' in template`. Both diagnostics identify the Ruby source. | E2.S2 |
| `06-svg-each.md` | SVG paths enter the live document with valid `d` values, without console errors. | **reproduced-defect:** `06-svg-each` ultimately has two correct SVG paths, but Chromium reports two invalid moveto errors during insertion containing the placeholder marker. Final correct attributes do not close this report. Other engines may be silent. SVG custom-element children remain explicitly deferred. | E3.S1 |
| `07-bind-and-handlers.md` | Binding synchronizes state before the explicit handler for the same native event. | **reproduced-defect:** `07-binding-handler` shows input value `needle`, Ruby query empty, and callback observation `:a`. **supported-in-isolation:** selecting `b` updates project and callback observation to `:b`. This separate native input/change sequence does not establish same-event composition or attribute-order independence. | E2.S3 |
| `08-event-target-dataset.md` | Target data stays target data; an explicit handler/current-target dataset exposes row ID even on descendant clicks. | **intentional-contract:** `08-event-dataset` observes empty target data for a span click and `log-001` for a direct row event. **reproduced-defect/API gap:** `current_target_dataset` is absent (renders empty). Descendant selection is not fixed by changing existing target semantics. | E3.S2 |
| `09-missing-platform-apis.md` | Optional Ruby APIs cover bounded data/time, measurement, wheel, shortcuts, and downloads without adding unused application payload. | **reproduced-defect/API gaps:** `09-json`, `09-time`, `09-math`, `09-regexp` fail mounting with `unknown class`; `09-wheel` receives neither delta (`:` instead of `4:12`). Other requested APIs and explicit deferrals are listed below. Existing files and icons are not missing capabilities. | E5.S1–E5.S3, E6.S1–E6.S3; explicit deferrals below |
| `10-ruby-gaps.md` | `next if line == ""` skips only that iteration. `redo` retains Ruby keyword meaning. | **supported-in-isolation:** `10-next` renders `alpha,beta`. Original larger-component unknown-method error remains **unresolved**. **intentional-contract:** `10-redo` rejects the bare keyword with an authored location; use a real method name. Array semantics are repaired by E1.S2; helper failures remain separately captured in 03. | E1.S2, E1.S3 |
| `11-boolean-typecheck.md` | Documented `prop :enabled, Boolean, default: false` works in both runtime and typecheck. | **supported-in-isolation:** `11-boolean` renders `false`. **reproduced-defect:** compiling the identical source with `--typecheck` exits 1 with `Unable to resolve constant Boolean` at the prop declaration. | E2.S4 |
| `12-assets-and-css-imports.md` | Public assets retain the documented output path; CSS resolution and icon packaging have explicit source-backed behavior. | **intentional-contract:** `12-assets-css` serves `/public/probe.svg`, resolves `lib/nested/../themes/base.css`, applies its color, and packages only the referenced `home` icon. **intentional-contract:** `12-missing-css` fails at build time with component/path details. **reproduced-defect:** `12-root-css` cannot import a present project-root `styles/base.css` through `../../styles/base.css`: the isolated compiler tree omits that directory. This differs from direct StyleComposer support. | E7.S2: document supported source layout and resolve or explicitly retain the root-style boundary |

### Boundaries not established by these probes

The synthetic workload in report 04 preserves nested hashes/arrays, concatenation, and repeated scans, but not every byte and binding of the application. It does not reproduce the reported 32,738-byte allocation failure or prove that 480 arbitrarily large records fit. Default scratch limits remain 2,048 objects and 131,072 bytes. E4 must test realistic structured records, resource lifetimes, and failure/recovery, using existing configuration rather than silently raising global budgets.

Report 09 is a capability inventory, not one executable expression. JSON parse is probed; JSON generation/`require "json"` loading and error contracts belong to E6.S1. Time.now is probed; the timestamp subset belongs to E6.S2. Measurement, owned resize callbacks, and wheel handling belong to E5.S1/E5.S2; owned global shortcuts to E5.S3; actual browser downloads to E6.S3. No supported Ruby API is invented here merely to make a negative probe. These broader contracts remain unresolved until their stories deliver them.

Full Math, Date/timezone breadth, Regexp/query parsing, slots, arbitrary DOM/window access, and SVG custom-element composition are explicit deferrals. Mochi's existing formatters, focus helpers, and focus-trap support do not imply those capabilities. Bounded files and static icons are already available: the default whole-file limit is **48,000 bytes**, not a two-megabyte promise; 8,192-byte chunks support larger bounded streaming reads. Icons are selected from project `icons/` assets and emitted on demand, not supplied as an implicit Lucide catalog.

## Related framework coverage

These links identify related coverage, not retroactive proof that a new report is fixed:

| Reports | Existing coverage and limits |
| --- | --- |
| 01, 05 | [framework standalone browser tests](../e2e/tests/gvm_framework_standalone.spec.ts), [each row compiler](../compiler/spec/html/each_row_compiler_spec.cr), [template expressions](../compiler/spec/html/template_expression_spec.cr). Smaller contextual rows/conditionals do not prove mixed table branches. |
| 02, 03, 10 | [source preparation](../compiler/spec/gvm/source_preparer_spec.cr), [Ruby surface](RUBY_SURFACE.md), framework numeric/collection browser tests. Slicing now has direct E1.S2 VM/browser coverage; aggregation and singleton success do not prove qualified constants. |
| 04 | [capacity config](../compiler/spec/gvm/capacity_config_spec.cr), [capacity boundaries](../e2e/tests/gvm_capacity_boundaries.spec.ts), [capacity contract](CAPACITY_CONTRACT.md). Config tests build two isolated profiles, validate limits, and verify VM source stays unchanged. |
| 06–09 | [loader tests](../runtime/test/mochi-loader.test.js), [pointer contracts](../e2e/tests/gvm_pointer_contracts.spec.ts), [drag/file contracts](../e2e/tests/gvm_drag_file_contracts.spec.ts), [file adapter tests](../runtime/test/mochi-files.test.js). File tests cover exact bounds, streaming, cancellation and lifetime cleanup. |
| 11 | [Sorbet integration](../compiler/spec/sorbet/integration_spec.cr) and [component generation](../compiler/spec/webcomponents/component_generator_spec.cr). A successful runtime prop declaration does not imply a clean typecheck. |
| 09, 12 | [style/icon composition](../compiler/spec/webcomponents/style_composer_spec.cr) and [build asset copying](../compiler/src/entrypoints/building/build_main.cr). Direct style composition accepts component-relative imports; the full build only stages supported source roots. |

## Artifact identity and verification

Recorded 2026-11-13, before any compiler/runtime changes for this plan:

| Artifact | Identity |
| --- | --- |
| Mochi source HEAD | `152ac661662c0bede8544345083990e5f7281861` plus this fixture/evidence change |
| GVM source HEAD | `90c881b3f02f16e23d77fe2abf142918ebc7d5cc` |
| `compiler/mochi` SHA-256 | `62b83e43bdfa4115fa4ef622a7c891ec079d1caf6a927e982d7abdde73df7934` |
| Emitted `mochi-loader.js` SHA-256 | `ccd5eb4dbd1ff334af9d0304d5b1278027d8ab84b97567dff85b38bccf8345e0` |
| Emitted `mochi-gvm.wasm` SHA-256 | `78deb591896501aa3420582a392b9e7642771fb53007b54671b3f40927fefab4` |
| Emitted `mochi-gvm.js` SHA-256 | `aeca5be31a2c9c0f735663a324174154bb1a5b2ed5f0c521c383d1ea3c000e2d` |
| `build_wasm/mruby/src/build/mochi-v2-host/bin/mrbc` SHA-256 | `3ee74223995996177d80b3fcb6e89cad5e51d655087fb90682a97a8e3b9eb7f3` (mruby 4.0.0) |
| Emitted capacity fingerprint | `ca1ab3a36bdb2da78e5960cdd94765b452ef749f9961c25a38465a7a5e934118` |

Runtime hashes were checked against an actual temporary inspector build, not inferred solely from VM distribution files. Compiler provenance is the binary hash; a source HEAD alone does not prove how an existing binary was built. Per-probe generated identities are available in test report attachments. No new runtime bytes, optional packages, capacity overrides, benchmark, or telemetry were introduced.

Fresh verification:

- **90 checks passed** across Chromium, Firefox, and WebKit: all 29 UI evidence/baseline checks plus the existing interactive child-prop test on each engine. The Ruby workflow check runs both authored inspector scenarios on each engine. No skipped tests.
- File adapter suite: **14 passed** (`node --test runtime/test/mochi-files.test.js`).
- Style/icon and capacity compiler suites: **11 examples passed**, no pending tests (`crystal spec spec/webcomponents/style_composer_spec.cr spec/gvm/capacity_config_spec.cr`, with repository library/link settings).
- Ruby syntax, evidence links, and change whitespace checks passed.

The browser command, from `e2e/`, was:

```sh
PLAYWRIGHT_HTML_OPEN=never npx playwright test \
  tests/gvm_ui_contracts.spec.ts tests/gvm_framework_standalone.spec.ts \
  --grep 'inspector|feedback evidence|compiled Ruby child props' \
  --reporter=line,html --workers=3
```

The passing evidence suite deliberately keeps current defects visible through explicit assertions; it does not mean those defects are repaired.

E7.S1 adds the [shared fixture workflow](../e2e/fixtures/ui_contracts/README.md): `task framework:ui` and inspector/graph/form targets, automatic Ruby suite discovery, `mochi test --test-file`, and console/page/runtime diagnostic checks with consumed, explicitly matched negative expectations. The complete suite is included in `framework:e2e`. Graph/form targets currently run their isolated evidence; their Ruby fixtures still belong to E3.S1/E2.S1. No fixture acceptance test is skipped to stand in for those future stories.

The E1.S1 binary identities and observations above remain the historical baseline. E7.S1 rebuilds the compiler to embed the updated test runner; it changes no application runtime or VM payload. E1.S2 follows that historical baseline; its results are recorded below.

E7.S1 validation: `task framework:e2e` passed **288 checks** (228 main framework/UI checks and 60 asset/install/evolved-feature checks), across Chromium, Firefox, and WebKit. `task runtime:test` passed **191 tests**. Initializer and installation-path specs passed **9 examples**. The new runner scenarios verify startup/mount/click console errors, page exceptions, expected mount rejection, matched-error consumption, unrelated/missing/dangling expectations, authored driver-error locations, and page/build/server cleanup. No new regression is skipped.

One earlier full-workflow invocation encountered an **unresolved** compiler-process failure during the Boolean typecheck probe: Crystal reported `Negative count: -1459520515` from buffered output during exit, rather than the expected Sorbet failure. The assertion correctly failed. The three-engine isolated probe and the subsequent complete workflow passed without relaxing the diagnostic assertions or adding retries. This is not evidence that the compiler-process issue is fixed; E2.S4 retains the Boolean/typecheck investigation boundary.

### E1.S2: array contracts repaired

`Array#slice(index)`, `slice(start, length)`, and `[](start, length)` now share
checked VM dispatch. Single-index bytecodes retain scalar behavior and check
unsupported index types. The existing compiler emits two-argument indexing as
method dispatch, so no bytecode/verifier change was required. Scratch and
persistent receivers return fresh shallow slices with the
[documented Ruby boundary table](RUBY_SURFACE.md#array-indexing-and-slicing).
The inspector uses ordinary slicing; no application workaround remains for
pagination. Graph history acceptance still belongs to E3.S3.

The new `02-array-contexts` Ruby scenarios check initialization, helpers,
handlers, and template getters, including a native Ruby boundary oracle.
Separate framework assertions verify authored method/source locations and
the requested/used/capacity fields of exhaustion errors. A 5,000-element
persistent array fails a full slice against the unchanged 4,096-slot scratch
limit, leaves its prior output intact, and then successfully slices its final
two elements. VM tests additionally cover object exhaustion, shallow nested
identity, receiver preservation, and allocation of only the returned elements.
The runner's intentional mount rejection now uses its own missing-method
fixture instead of depending on the repaired `slice` failure.

Fresh verification, 2026-11-13:

- `goosetest test`: **213 cases, 20,923 assertions passed**. Mirror audit:
  **35 matched, zero missing/orphaned**.
- `task framework:ui`: **138 checks passed** across Chromium, Firefox, WebKit.
- `task framework:e2e`: **294 checks passed** (234 framework/UI plus 60
  asset/install/evolved-feature checks), with no skips.
- `task payload`: passed after recording exactly **2,007 raw / 887 gzip bytes**
  of essential VM semantics in the core budget; optional downloads unchanged.
- `task compile-time:framework`: all **15 builds passed**, 136.6–142.4 ms
  against the strict 1,000 ms limit.
- Goose formatting and whitespace checked. The only changed-file lint
  diagnostic is the pre-existing G014 length violation in
  `vm_call_object_builtin`, also reproduced against HEAD.

Rebuilt WASM SHA-256:
`bf6a78f5136c7071d2916960d69fec9ca66893a55213ace65e5a9cdf66dcca08`.
Per-probe compiler/source/bundle hashes remain attached to browser reports.
Array `.to_s` and direct text rendering still return empty; the original
expressions remain visible in report 02's probes, alongside explicit
length/content assertions. This does not claim Array rendering support.
Next in the recommended order: E1.S3.
