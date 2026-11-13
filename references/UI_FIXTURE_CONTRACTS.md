# UI fixture contracts: 2026-11-13 feedback batch

E1.S1 establishes a standalone inspector and records current behavior. It does **not** close the later compiler, VM, or browser capability stories. All results below are Mochi-owned probes; no application checkout is needed to compile or run them.

The source reports are the twelve files in `/Users/bob/repos/sencha/feedback/`, discovered during implementation. The plan calls them Cowboy feedback; their filenames and contents identify this batch. The seventeen entries in [FEEDBACK_CONTRACTS.md](FEEDBACK_CONTRACTS.md) are an older, independently numbered inventory. For example, this batch's `09-missing-platform-apis.md` is unrelated to that inventory's `009 Root-level conditional`. Neither inventory supersedes the other.

## Runnable baseline

[InspectorRoot.rb](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb) generates 48 deterministic records, each with a stable string ID, severity, message, and nested source/sequence details. It renders 12 records per page, filters by a literal message substring, clamps page bounds including empty results, and retains selection by ID. Records remain hashes throughout. It uses no service, external asset, app-authored JavaScript, or optional browser capability.

The E1.S1 baseline used a bounded scalar-index loop for page extraction. E1.S2 now uses `matches.slice(@page * 12, 12)` and verifies first, middle, last, filtered, and empty pages. E1.S3 now owns generation and filtering through `RecordData`, with qualified page-size constants; E4.S1/E4.S2 own computed projections. These stages are explicit, not claims that the missing facilities are already supported.

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
| `01-block-conditionals-and-loops.md` | Block `if` inside table rows, `each` inside `if`, and nested `each` preserve lexical scope and structure. | **supported, repaired by E2.S1:** all three original probes render their expected rows. `NestedFormRoot` and `01-structural-contexts` add initially open/closed nesting, table/select/HTML/SVG contexts, row props/events, local shadowing, keyed identity, and branch disposal/recreation. Source-located malformed expressions and invalid table nesting remain build errors. | E2.S1 |
| `02-array-slice-and-brackets.md` | `[1,2,3,4][1,2]` and `.slice(1,2)` return a fresh `[2,3]`. | **supported:** both probes now return a fresh two-element array containing `2,3`. `02-array-contexts` verifies Ruby boundaries, initialization/helper/handler/template parity, shallow identity, source-located errors, and slot exhaustion/recovery. Original `.to_s` expressions remain in the probes: Array text rendering still returns empty and is a separate unresolved surface, not a slicing failure. | E1.S2; history acceptance E3.S3 |
| `03-qualified-constants.md` | `RecordData::BASE` and `RecordData.base_ms` return `1794571200000` in component contexts. | **supported:** both original probes return the correct value. `03-helper-contexts` compares direct Ruby with initializer, ordinary method, handler, and template results; separate helpers retain independent `BASE` values. Missing constants/methods name their references and the component call site. Arbitrary nested module/class registration remains outside this contract. | E1.S3 |
| `04-scratch-capacity.md` | Structured local data work either completes correctly or reports the actual configured resource; later valid work recovers. | **supported-in-isolation:** `04-structured-records` mounts 480 hashes with nested attribute arrays; `04-concatenation` builds 360 lines / 24,370 bytes; `04-repeated-split` evaluates 480-line splits in 20 bindings. No exhaustion occurs for these inputs. Original richer object/byte exhaustion and repeated-update/recovery behavior remain **unresolved**. Configurability is an existing, tested **intentional-contract**. | E4.S1–E4.S3 |
| `05-template-attribute-quoting.md` | Double-quoted Ruby hash keys work inside double-quoted HTML attributes and conditional classes. | **supported, repaired by E2.S2:** both original probes render `Open record` with the `ghost` class and the expected aria-label. The nested form adds both quote styles, nested interpolation, escaped quotes, typed props, event arguments, literal braces/entities, and adversarial labels that remain text. Malformed expressions retain authored source diagnostics. | E2.S2 |
| `06-svg-each.md` | SVG paths enter the live document with valid `d` values, without console errors. | **supported, repaired by E2.S1 shared fragment lowering:** dynamic SVG attributes are inert during parsing and receive evaluated values before insertion. `06-svg-each` checks both paths and zero console errors; structural context tests add circle/rect branches, toggles, and HTML inside foreignObject. The editable graph fixture remains E3.S1; SVG custom-element children remain explicitly deferred. | E2.S1 shared fix; E3.S1 graph |
| `07-bind-and-handlers.md` | Binding synchronizes state before the explicit handler for the same native event. | **reproduced-defect:** `07-binding-handler` shows input value `needle`, Ruby query empty, and callback observation `:a`. **supported-in-isolation:** selecting `b` updates project and callback observation to `:b`. This separate native input/change sequence does not establish same-event composition or attribute-order independence. | E2.S3 |
| `08-event-target-dataset.md` | Target data stays target data; an explicit handler/current-target dataset exposes row ID even on descendant clicks. | **intentional-contract:** `08-event-dataset` observes empty target data for a span click and `log-001` for a direct row event. **reproduced-defect/API gap:** `current_target_dataset` is absent (renders empty). Descendant selection is not fixed by changing existing target semantics. | E3.S2 |
| `09-missing-platform-apis.md` | Optional Ruby APIs cover bounded data/time, measurement, wheel, shortcuts, and downloads without adding unused application payload. | **reproduced-defect/API gaps:** `09-json`, `09-time`, `09-math`, `09-regexp` fail mounting with `unknown class`; `09-wheel` receives neither delta (`:` instead of `4:12`). Other requested APIs and explicit deferrals are listed below. Existing files and icons are not missing capabilities. | E5.S1–E5.S3, E6.S1–E6.S3; explicit deferrals below |
| `10-ruby-gaps.md` | `next if line == ""` skips only that iteration. `redo` retains Ruby keyword meaning. | **supported:** `10-next` renders `alpha,beta`; E1.S3 adds nested `each`, `map` with `next value`, lexical-local updates, and continuation after iteration across helper/component contexts. **intentional-contract:** `10-redo` rejects the bare keyword with an authored location; use a real method name. Array semantics are repaired by E1.S2; E1.S3 covers helper parity in 03 and rejects unsupported nonlocal control flow before mounting. | E1.S2, E1.S3 |
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
| 01, 05 | [structural composition specs](../compiler/spec/html/structural_composition_spec.cr), [attribute scanner specs](../compiler/spec/html/template_attributes_spec.cr), [template expressions](../compiler/spec/html/template_expression_spec.cr). E2.S1 covers mixed branches and contexts; E2.S2 covers Ruby-aware attribute boundaries and escaping. |
| 02, 03, 10 | [source preparation](../compiler/spec/gvm/source_preparer_spec.cr), [Ruby surface](RUBY_SURFACE.md), framework numeric/collection browser tests. E1.S2/E1.S3 now directly cover slicing, scoped helper constants/receivers, and local block next in VM/compiler/browser tests. |
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

E7.S1 adds the [shared fixture workflow](../e2e/fixtures/ui_contracts/README.md): `task framework:ui` and inspector/graph/form targets, automatic Ruby suite discovery, `mochi test --test-file`, and console/page/runtime diagnostic checks with consumed, explicitly matched negative expectations. The complete suite is included in `framework:e2e`. E2.S1 now adds the form's Ruby scenarios and lifecycle/context assertions; the graph fixture remains E3.S1. No fixture acceptance test is skipped to stand in for a future story.

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
E1.S3 follows this historical verification; its results are recorded below.

### E1.S3: helper receivers, constants, and block next

`RecordData` now owns inspector generation and filtering. Scoped constant
storage and executable `GETMCNST` support fix `RecordData::BASE`; method and
block frames retain the defining helper's lexical owner. Packaging exports
`RecordData::BASE` instead of an unrelated global `BASE`. Explicit singleton
calls keep their receiver, including missing-method diagnostics. Source
preparation preserves these forms without rewriting them into literals.

The verifier previously started RITE sections at byte 22 instead of 20, so
its stale opcode table was bypassed. It now walks real records and every
nested IREP using the current mruby 4.0 opcode numbers. Unsupported unwind
operations, exception handlers, and `redo` fail before bundle emission.
A second, temporary debug compile supplies authored opcode-error lines;
normal shipped bytecode gains no debug section. Compiler doubles now emit a
valid minimal RITE fixture, so they cannot mask a verifier bypass.

`next` already compiled to correct local block returns. Real-bytecode Goose
tests and native-Ruby browser oracles now verify each/map results, nested
iteration, lexical locals, and enclosing-method continuation. Block `break`
and nonlocal block `return` are explicitly rejected instead of incorrectly
acting like local returns. Runtime diagnostics preserve the existing
component method-declaration/template-binding source granularity. Arbitrary
nested class/module registration and full exception unwinding remain outside
the supported helper contract described in [Ruby surface](RUBY_SURFACE.md).

Verification on 2026-11-13:

- `task specs`: **518 examples passed**, no failures/errors/pending.
- `goosetest test`: **215 cases / 20,943 assertions passed**; mirror audit:
  **36 matched**, zero missing/orphaned tests.
- `task framework:e2e`: **303 checks passed** across Chromium, Firefox, and
  WebKit (243 main framework/UI plus 60 asset/install/evolved-feature checks).
- After the final template dependency regression was added, `task specs`
  passed again and `task framework:ui` passed **147 checks** on all engines.
  Qualified template references do not load an unrelated global `BASE` package.
- `task payload` passed with exactly **1,038 raw / 534 gzip bytes** added to
  core WASM. No optional adapter, debug section, or capacity override was added.
- `task compile-time:framework`: all **15 builds passed** below 1,000 ms.
- Crystal formatting, Ruby syntax, and whitespace checks passed. Goose changed
  files retain only pre-existing G010/G014 file/function-length diagnostics,
  reproduced against HEAD; new constant code/tests have no lint diagnostics.

Final compiler SHA-256:
`277f131bde639798f28c7c7346f89e4e800716bef7cfdb12668224926affef9b`.
Final WASM SHA-256:
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
The historic E1.S1/E1.S2 identities above remain unchanged as evidence.
Next in the recommended order: E2.S1.

### E2.S1: mixed structural fragments and nested form

[NestedFormRoot](../e2e/fixtures/ui_contracts/lib/NestedFormRoot.rb) and its
typed [FieldEditor](../e2e/fixtures/ui_contracts/lib/FieldEditor.rb) child now
exercise keyed groups/fields, conditional help and validation, initially
closed mounting, edits, reorder, neighbor insertion/removal, and recreation.
The E2.S1 baseline used explicit input handlers and left attribute quotes,
same-event binding composition, and Boolean typechecking to E2.S2–E2.S4.
E2.S2 results below supersede that quote-scanning limitation.

Rows and branches share a compiled fragment representation with lexical
scope, source spans, slots, events, and structural children. Branches add no
loop context. Generated Ruby evaluates only the selected row branch and uses
block-local aliases so nested loops cannot overwrite outer item/index values.
Dependency discovery also scans generated Ruby: helpers referenced only in
conditions, slots, keys, or event arguments remain reachable without loading
unused helpers. Review caught this dependency gap; the package graph spec and
`RowGate` browser probe retain the regression.

Table/select/SVG/HTML fragments preserve actual insertion context. Dynamic
SVG attributes remain inert until evaluated slots are assigned, repairing
report 06's transient invalid path diagnostics as part of shared lowering.
This does not complete E3.S1's editable graph or add SVG custom elements.
Malformed branch expressions and invalid table fragments retain authored
source diagnostics.

The framework suite retains actual editor nodes and VM instances across
keyed moves. Three removal/recreation cycles verify cleared binding targets,
released route subscriptions, stable component/binding/resource counts,
fresh props/local state, current event indices, and no duplicate handlers.
Console and page capture starts before insertion. A loader unit regression
also switches row branches with keyed descendants and verifies draft retention
versus fresh state. The Ruby runner's `wait_for_settled` now includes lazy
child mounts; a delayed descriptor test proves the wait. Cleanup tests use a
dedicated invalid-source fixture instead of the repaired report 01.

Verification on 2026-11-13:

- `task specs`: **525 examples passed**, no failures/errors/pending.
- `task runtime:test`: **192 tests passed**, no skips.
- `task framework:ui`: **162 checks passed** across Chromium, Firefox, WebKit.
- Final `task framework:e2e`: **318 checks passed** (258 main framework/UI
  plus 60 asset/install/evolved-feature checks), with no skips. After extending
  the context probe to insert directly beneath `foreignObject`, all **six**
  initially open/closed context checks passed again on the three engines.
- `task payload`: passed with exactly **2,272 raw / 488 gzip bytes** added to
  the core loader. WASM, optional downloads, and capacity limits are unchanged.
- `task compile-time:framework`: final run passed all **15 builds**,
  **204.0–231.4 ms**, against the strict 1,000 ms limit. The preceding run
  failed its first cold build at **2,049.8 ms** while its other 14 builds
  passed. Cause remains unestablished; the passing repeat does not establish
  that the outlier is repaired. No threshold or retry policy was changed.

Final compiler SHA-256:
`c1684778edb4bb777fa0db0dd61818a33a6610b675c1ee32f3b5d48fdebb2281`.
Loader SHA-256:
`73249a3f30119134d84c80231e64753250af47b2f76e8fda8455e0eaf9295649`.
Unchanged WASM SHA-256:
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe source, descriptor, bytecode, and bundle identities remain attached
to the browser reports. All implementation changes stay in Mochi; no GVM or
external application edits are required.
Crystal formatting, Ruby/JavaScript syntax, documentation links, and whitespace
checks passed. Next in the recommended order: E2.S2.

### E2.S2: Ruby-aware attribute expressions

One [attribute scanner](../compiler/src/html/template_attributes.cr) finds
attribute boundaries while skipping complete Ruby placeholders. Conditional
attributes, attribute hashes, events, and row event metadata use those spans.
The shared expression scanner handles nested string interpolation, escaped
quotes, percent-literal delimiters, and adjacent hash braces. Structural
scanners skip whole expressions, so strings containing `{if ...}` or `{end}`
cannot become template blocks.

Ruby source remains intact through lowering. Only the HTML parser boundary
encodes placeholder contents; one HTML decode restores exact expressions for
text, attribute, and prop bindings. Generated conditional-attribute methods
quote literal pieces separately from Ruby expressions and decode literal HTML
entities once. Literal brace escaping leaves Ruby expressions intact. Quoted
attribute hashes and doubled-brace literals follow the explicit grammar in
[Ruby surface](RUBY_SURFACE.md#ruby-expressions-inside-attributes); malformed
explicit hashes still fail validation.

Event strings with escapes or interpolation execute through Ruby. Plain
literal strings keep their existing fast path. Browser coverage also exposed
an event-cache collision: a text/attribute binding with the same expression
suppressed the hidden event binding, although only hidden `expr` bindings
export the expression identity used by dispatch. Deduplication now uses only
`expr` bindings in the current branch's list. The nested form exercises that
exact attribute/event combination.

Both original report 05 probes now assert successful rendering. The form's
new Ruby scenario and framework test put quotes, `<img>` text, ampersands,
literal entities, and `{end}` into labels. Static and conditional attributes,
nested rows, typed child props, event arguments, and recreated branches retain
the exact values; no image/script/injected attribute appears. Compiler tests
check source-located malformed input in ordinary, branch, row, conditional
attribute, and event contexts. Inputs still use explicit handlers; E2.S3 owns
binding/handler composition and E2.S4 owns Boolean typechecking.

Verification on 2026-11-13:

- `task specs`: **537 examples passed**, no failures/errors/pending.
- `task runtime:test`: **192 tests passed**, no skips.
- `task framework:e2e`: **321 checks passed** across Chromium, Firefox, and
  WebKit (261 main framework/UI checks, including all 165 UI/workflow checks,
  plus 60 asset/install/evolved-feature checks). An earlier UI run exposed
  the event-cache collision described above; its regression now passes.
- `task payload`: passed with **zero core or baseline payload growth**.
  Core remains **494,862 raw / 159,867 gzip bytes**; optional downloads and
  budgets are unchanged. Generated expression helpers ship only with the
  components using them; no VM or runtime JavaScript change is needed.
- `task compile-time:framework`: final isolated run passed all **15 builds**
  at **201.2–211.0 ms**, below the unchanged 1,000 ms limit. The first run
  after rebuilding failed its first cold invocation at **2,229.3 ms**;
  the remaining 14 passed. The first-launch outlier recorded in E2.S1 remains
  unresolved. A temporary copy of the same binary took **1,397.7 ms** for its
  first `--help` invocation and **235.0 ms** for its second, demonstrating a
  launch delay even without an application compile. This does not establish
  the underlying cause or repair the outlier; no threshold/retry policy changed.
- Crystal formatting, Ruby syntax, documentation links, and whitespace checks
  passed. No commits were made.

Compiler SHA-256:
`e596e3b29fee51af19b3db9505840aa2cf9bd7e514a5351440fd5975b6ecd7e8`.
Loader SHA-256 remains
`73249a3f30119134d84c80231e64753250af47b2f76e8fda8455e0eaf9295649`;
WASM remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe artifacts remain attached to browser reports. No GVM or external
application files changed, and no regression is skipped.
Next in the recommended order: E2.S3.
