# UI fixture contracts: 2026-11-13 feedback batch

The three portable Ruby fixtures now exercise the supported contracts below.
Every report has a supported, intentional, or deferred disposition; this does
not claim full Ruby compatibility or reproduction of every original product
workload. No external application checkout is needed to build or run evidence.
See the [completion audit](#completion-audit-al-dente) for current check results
and the [E7.S2 checkpoint](#final-verification-e7s2) for its artifact identities;
chronological results later in this file are historical.

The twelve source reports were discovered in `/Users/bob/repos/sencha/feedback/`
(the plan calls this Cowboy feedback). Their **01–12 filenames identify this
batch**. The seventeen **001–017** reports in
[FEEDBACK_CONTRACTS.md](FEEDBACK_CONTRACTS.md) belong to an older inventory.
For example, new report 09 is platform APIs; older report 009 is a root-level
conditional. Probe prefixes such as `12-computed` and `14-download` are test
organization, not additional feedback report IDs.

## Run the contracts

See the [fixture guide](../e2e/fixtures/ui_contracts/README.md) for each model,
interactions, negative scenarios, and source-linked Ruby examples.

```sh
task framework:ui            # all three engines, fixtures and contract probes
task framework:ui:inspector
task framework:ui:graph
task framework:ui:form
task framework:e2e           # complete portable framework and asset/install suite
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=download_test.rb --browsers=chromium
```

The [runner/helper](../e2e/tests/framework_helpers.ts) compiles and serves
isolated temporary projects. Intentionally invalid probes live outside the
shared project's `lib/`. Authored scenarios remain Ruby. Browser framework
checks additionally inspect node identity, SVG values before insertion,
downloaded bytes, lifecycle resources, and unexpected console/page errors.

## Final report dispositions

All named `feedback evidence` checks and other browser titles below are in
[the UI contract suite](../e2e/tests/gvm_ui_contracts.spec.ts), except where a
different suite is linked. Each probe name links to its checked-in source.

| Report | Current contract and limitation | Exact evidence |
| --- | --- | --- |
| `01-block-conditionals-and-loops.md` | **Fixed/supported:** nested `if`/`each` preserve lexical scope, HTML/SVG context and keyed identity. Malformed expressions/table nesting are intentional build errors. | `feedback evidence` for [01-if-in-each](../e2e/fixtures/ui_contracts/probes/01-if-in-each), [01-each-in-if](../e2e/fixtures/ui_contracts/probes/01-each-in-if), [01-nested-each](../e2e/fixtures/ui_contracts/probes/01-nested-each); `structural fragments retain table/select/HTML/SVG context, initially 0/1`; [nested form scenarios](../e2e/fixtures/ui_contracts/test/nested_form_test.rb). |
| `02-array-slice-and-brackets.md` | **Fixed/supported:** scalar indexing and fresh shallow slices follow the documented boundary table in every component context; invalid arguments and exhaustion report errors and recover. Range coercion and direct Array text rendering are deferred. | `Ruby array slice contracts across contexts and failure recovery`; `array errors retain authored methods, source lines, and capacity details`; [MRI-oracle Ruby scenarios](../e2e/fixtures/ui_contracts/probes/02-array-contexts/test/array_slice_test.rb). |
| `03-qualified-constants.md` | **Fixed/supported:** qualified helper constants and singleton receivers retain lexical ownership in initializer/method/handler/template calls. Arbitrary nested class/module registration is outside the supported subset. | `Ruby helper receivers, constants, and block next across contexts`; `missing helper references retain authored source and receiver`; [helper scenarios](../e2e/fixtures/ui_contracts/probes/03-helper-contexts/test/helper_test.rb). |
| `04-scratch-capacity.md` | **Supported bounded contract:** structured 480-record working set, explicit resource diagnostics, failure isolation/recovery, and repeated lifecycle reuse. Exact original product allocation is not claimed reproduced; no promise that arbitrarily large records fit. | [100 interaction/100 mount cycles](../e2e/tests/gvm_ui_capacity_lifecycle.spec.ts), `three fixtures reuse a bounded profile through 100 interaction and 100 mount cycles`; [capacity boundaries](../e2e/tests/gvm_capacity_boundaries.spec.ts), `computed lifecycle: … preserves DOM and recovers with an independent instance` and `failed computed mount releases caches and bindings before a valid remount`; original `04-*` observations. |
| `05-template-attribute-quoting.md` | **Fixed/supported:** Ruby-aware quoted expressions preserve values across attributes, props, rows and event arguments; hostile labels remain data. Malformed syntax fails at authored source. | `quoted form labels stay data across attributes, props, branches and events`; [nested form scenario](../e2e/fixtures/ui_contracts/test/nested_form_test.rb) `quoted expressions retain Ruby values across form contexts`; [05-attribute-quotes](../e2e/fixtures/ui_contracts/probes/05-attribute-quotes) and [05-conditional-quotes](../e2e/fixtures/ui_contracts/probes/05-conditional-quotes). |
| `06-svg-each.md` | **Fixed/supported:** native SVG has valid geometry before insertion, canonical names/namespaces, and keyed updates. SVG custom-element composition remains deferred. | `graph SVG insertion and keyed updates (initial open=true/false)`; [graph scenarios](../e2e/fixtures/ui_contracts/test/editable_graph_test.rb); [06-svg-each](../e2e/fixtures/ui_contracts/probes/06-svg-each). |
| `07-bind-and-handlers.md` | **Fixed/supported:** setter runs before arguments/handler once for the same event, independent of attribute order. Setter failure suppresses callback and successful flush; later input recovers. | [binding scenarios](../e2e/fixtures/ui_contracts/test/binding_actions_test.rb), `bindings precede handlers in either attribute order` and `bound row handlers retain scope after moves and branch recreation`; `bound setter capacity failure blocks callback and permits later valid events`. |
| `08-event-target-dataset.md` | **Supported explicit contract:** `dataset`/`target_dataset` describe the retargeted target; `current_target_dataset` identifies the bound handler. Descendant clicks preserve row identity. Transport bounds remain intentional. | `graph and inspector select bound identities from surfaces and descendants`; `target and handler dataset overflow reports source and permits later clicks`; [event-identity scenarios](../e2e/fixtures/ui_contracts/probes/08-event-dataset/test). |
| `09-missing-platform-apis.md` | **Delivered bounded subset:** JSON, UTC Time instants, formatting, layout, wheel, shortcuts, and downloads. Files/static icons already exist. Full Math/Regexp/Date breadth, arbitrary DOM/window access, save pickers and streaming downloads remain deferred. | `JSON errors recover through ordinary Ruby calls`; `Ruby timestamp conversions and error recovery`; `optional layout fits real resized graph bounds and stops observation`; `wheel zoom preserves measured pointer anchor, units, limits, and drag`; `active form shortcut scope suppresses graph actions and restores focus`; [download scenarios](../e2e/fixtures/ui_contracts/test/download_test.rb); negative [09-math](../e2e/fixtures/ui_contracts/probes/09-math) / [09-regexp](../e2e/fixtures/ui_contracts/probes/09-regexp) observations. |
| `10-ruby-gaps.md` | **Fixed/supported:** local block `next`, postfix `next if`, map values and nested loop continuation. **Intentional rejection:** bare `redo` is an unsupported Ruby keyword, not a handler name. Nonlocal block return/break and rescue/ensure remain unsupported. | `feedback evidence` for [10-next](../e2e/fixtures/ui_contracts/probes/10-next) and [10-redo](../e2e/fixtures/ui_contracts/probes/10-redo); [helper scenarios](../e2e/fixtures/ui_contracts/probes/03-helper-contexts/test/helper_test.rb); `feedback evidence 03-unsupported-rescue: compiler diagnostic`. |
| `11-boolean-typecheck.md` | **Fixed/supported:** required/default Boolean props work in build and typecheck, including conditional/keyed children; typed event mismatches reject before parent delivery and recover. The historical intermittent Sorbet process failure is not proven fixed. | `Boolean declarations typecheck and build: 11-boolean/11-boolean-contracts/shared-form`; `Ruby Boolean event contracts reject mismatches and recover`; [Boolean scenarios](../e2e/fixtures/ui_contracts/probes/11-boolean-contracts/test/boolean_test.rb). |
| `12-assets-and-css-imports.md` | **Intentional supported layout:** `public/` stays under output `public/`; component-relative CSS under staged source roots and referenced-only project icons work. Missing imports fail. **Retained limitation:** project-root `styles/` is not staged; use `lib/styles/`. This is documented, not claimed repaired. | `feedback evidence` for [12-assets-css](../e2e/fixtures/ui_contracts/probes/12-assets-css) verifies `/public/probe.svg`, applied CSS, emitted `home.svg` and absent `unused.svg`; [12-missing-css](../e2e/fixtures/ui_contracts/probes/12-missing-css) and [12-root-css](../e2e/fixtures/ui_contracts/probes/12-root-css) intentionally assert build diagnostics; [asset paths](../e2e/tests/gvm_asset_paths.spec.ts). |

## Limits and evidence rules

[Supported Ruby](RUBY_SURFACE.md) and the [fixture guide](../e2e/fixtures/ui_contracts/README.md)
define the accepted subset. Explicit deferrals include full MRI/Regexp/Date/Math,
slots, SVG custom-element composition, automatic deep mutation observation,
arbitrary DOM/window access and dynamic row refs, unbounded/general import/export,
and a reusable graph/form component library. Array `.to_s` is not part of the
slicing acceptance contract. Native desktop OS-drop verification remains a
[manual file-contract boundary](DRAG_FILE_CONTRACT.md#native-os-drop-verification).

Default scratch bounds are 2,048 objects/131,072 bytes. Whole-file reads cap at
48,000 bytes; larger inputs use bounded 8,192-byte chunks. JSON documents have
an independent 48,000-byte ceiling. Downloads cap one output at 262,144 bytes.
See [capacity configuration](../docs/fixed-capacities.md); successful isolated
probes never imply an unbounded product workload. A failed entry discards its
DOM patches/host commands but does not roll back earlier Ruby state writes.

Negative tests assert precise diagnostics, never skip or silently accept unrelated
errors. Compiler failures require a nonzero exit and authored location. Browser
capture starts before navigation; source-located `mochi:error`, console errors,
and page exceptions are checked. Repairing an unsupported contract requires
changing its negative test to ordinary acceptance. The HTML report's
`artifact-identity` attachments record compiler/source/bundle hashes and the
manifest/profile; console silence alone cannot prove correct transient SVG.

## Implementation history and historical artifact identities

The chronological notes below preserve what each story established at the time.
Their byte counts, hashes, test totals, and forward-looking limitations are
historical; the final report table above and E7.S2 verification below describe
the current checkout. Neither inventory renumbers the other.



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

E7.S1 adds the [shared fixture workflow](../e2e/fixtures/ui_contracts/README.md): `task framework:ui` and inspector/graph/form targets, automatic Ruby suite discovery, `mochi test --test-file`, and console/page/runtime diagnostic checks with consumed, explicitly matched negative expectations. The complete suite is included in `framework:e2e`. E2.S1 adds the form's Ruby scenarios and lifecycle/context assertions; E3.S1 adds the graph's Ruby scenarios and synchronous SVG insertion/identity checks. No fixture acceptance test is skipped to stand in for a future story.

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

### E2.S3: bound state before explicit handlers

The compiler retains ordered setter/callback actions and lowers each composed
native event into one Ruby entrypoint. The setter runs first; explicit argument
expressions evaluate afterward, so both the callback and its arguments see
current state. One existing dispatch/flush boundary handles the whole sequence.
The browser receives no action interpreter or expression source for these
arguments. Original callback names and bare argument references remain
validated. Generated entrypoints map diagnostics back to the bound expression.

Text `bind:value` uses `input`; checkbox `bind:checked` and select `bind:value`
use `change`. The select's native input/change pair therefore invokes its change
callback once. Attribute order does not decide which action survives. Modifiers
retain their existing synchronous behavior and implicit event payloads retain
the VM's leading-required-parameter rule. Row event wrappers preserve current
lexical scope, and property slots update edited controls through the existing
property writer. Keyed moves, branch recreation, and remount retain single
invocation behavior.

`FieldEditor` now validates its bound draft and emits that value directly.
`InspectorRoot` resets pagination from the current bound query, including a
query whose result still spans multiple pages. Neither uses deferred timers.
`BindingActionsRoot` adds Ruby-authored coverage for both attribute orders,
text/select/checkbox events, fresh argument values, row moves, property resets,
branch recreation, and remount. The original report 07 probe is now a passing
acceptance assertion.

The real VM failure probe admits a 310,000-byte event through a 400,000-byte
bridge and 524,288-byte scratch arena, then fails persisting it in a 300,000-byte
state pool. All three browsers observe the setter capacity error, unchanged
query/callback count, no callback storage effect, and successful recovery with
a small input. These capacities are isolated to that test bundle. This proves
setter short-circuiting, not transaction rollback of earlier successful writes.

Verification on 2026-11-13:

- `task specs`: **542 examples passed**, no failures/errors/pending. Includes
  execution of generated Ruby, setter abort, literal interpolation markers,
  optional/rest arities, action descriptors, and row scope/property slots.
- `task runtime:test`: **194 tests passed**, no skips. Added checks cover a
  single dispatch/flush, modifiers, discarded failed effects, and row properties.
- `task framework:e2e`: **327 checks passed** across Chromium, Firefox, WebKit
  (267 main framework/UI checks plus 60 asset/install/evolved-feature checks).
  This includes all **171 UI/workflow checks**; no regressions are skipped.
- `task payload`: passed after increasing baselines by exactly **363 raw /
  62 gzip bytes** for shared row property handling. Core is **495,225 raw /
  159,929 gzip bytes**. WASM, JS glue, optional downloads, and default capacity
  limits are unchanged. Ordered wrappers ship with using components only.
- `task compile-time:framework`: all **15 builds passed**, **200.0–211.3 ms**,
  below the unchanged 1,000 ms limit. This run occurred after browser/payload
  builds had launched the compiler; it does not resolve the first-launch
  outlier previously recorded in E2.S1/E2.S2.
- Crystal formatting, Ruby/JavaScript syntax, documentation links, composed
  argument diagnostics, and whitespace checks passed. No commits were made.

Compiler SHA-256:
`531c3996799934521d97becdbea95a64da0b0c6f5e7c947c8bdb0f5d8df18abd`.
Loader SHA-256:
`b37dc9282e324c2f3359e7a8ae4a0cd36ce0d88a60bfb755ef3573da1924bbde`.
WASM SHA-256 remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe artifacts remain attached to browser reports. No GVM or external
application source changed. Next in the recommended order: E2.S4.

### E2.S4: typed Boolean declarations and ordinary form behavior

[Component typecheck preparation](../compiler/src/sorbet/component_source_preparer.cr)
uses the existing declaration validator and rewrites Boolean type positions
only in recognized component `prop`/`event` calls. Sorbet sees `T::Boolean`
and component-local metadata/emitter shims. Authored files and shipped Ruby
remain unchanged; unrelated constants, helper DSL calls, and ordinary signed
method errors still fail. A byte-column map accounts for multiple same-line
adaptations, inline generated shims, and Unicode. CLI diagnostics now display
one-based authored lines and columns.

Form coverage exposed a separate defect: a declared child prop named
`required` or `disabled` lost its false value through native HTML Boolean
attribute handling. After resolving the component inventory, the compiler
marks declared prop bindings as textual values in static, conditional, and
row descriptors. Row lookup normalizes authored HTML case. The loader matches
attribute semantics to the exact slot, preserving native input behavior next
to a child with a same-named prop. Child descriptors remain lazy; no schema
or new adapter is added to initial loading.

`FieldEditor` now declares required/defaulted Boolean props and typed save/cancel
events. Associated labels, required inputs, conditional validation messages,
ARIA state, and native form submit behavior remain ordinary HTML. Save sends
the current draft and Boolean validity; the parent updates that field's saved
value. Cancel closes the form, discards unsaved local state, and uses the
existing named-ref focus API to return focus to the toggle. Reopening restores
saved values. Keyed moves preserve the focused input. Explicit zero tab indices
keep Save/Cancel in WebKit's tab sequence without replacing native keyboard
behavior. The Ruby runner adds `focus`, `press`, and `assert_focused`, including
nested shadow selectors and authored failure locations.

`BooleanPropsRoot` covers static/conditional props; repeated editors cover the
same false/true contract. `11-boolean-contracts` also passes `# typed: true`
builds, rejects a string Boolean event payload before parent delivery, and
then delivers a valid false value. The original report 11 probe and the shared
form both build with `--typecheck`. Literal default mismatches remain compile
errors. Defaults retain the documented narrower existing surface: nil is
allowed for all prop types, and constant defaults are not checked against the
prop type after Ruby evaluation. Dynamic event payload validation remains a
runtime contract; declaration shims do not promise static Hash field inference.

Verification on 2026-11-13:

- `task specs`: **548 examples passed**, no failures/errors/pending. Includes
  real Sorbet sessions, genuine negative diagnostics, source-column mapping,
  literal-default validation, and native-versus-child attribute descriptors.
- `task runtime:test`: **196 tests passed**, no skips. New checks cover exact
  row slot semantics and Ruby keyboard/focus recording.
- Final `task framework:e2e`: **336 checks passed** across Chromium, Firefox,
  WebKit (276 main framework/UI checks, including all 180 UI/workflow checks,
  plus 60 asset/install/evolved-feature checks). Earlier failures exposed a
  stale integer-valued mount test and WebKit's native tab policy; both now
  have direct passing coverage.
- `task payload`: passed with **96 raw / 22 gzip bytes** added to the loader.
  Core is **495,321 raw / 159,951 gzip bytes**. Budgets increase by exactly the
  measured delta. WASM, JS glue, optional downloads, and default capacities are
  unchanged; the typecheck and keyboard test adaptations are build/test-only.
- `task compile-time:framework`: all **15 builds passed**, **199.8–207.8 ms**,
  below the unchanged 1,000 ms limit. This run followed other compiler uses;
  it does not establish a repair for the historical first-launch outlier.
- Crystal formatting, Ruby/JavaScript syntax, documentation links, and
  whitespace checks passed. No commits were made.

The previously recorded **intermittent Sorbet process failure remains
unresolved**. One earlier full run hit `Negative count: -1459520515` during
`--typecheck` process exit; a separate context probe observed Sorbet's native
LSP owner-thread assertion preceding that same secondary failure. Local FFI
inspection found no proven safe ownership fix. The final complete run passed,
but no retry, skip, or diagnostic suppression was added, and that passing run
does not prove the native crash repaired.

Compiler SHA-256:
`170998b424c17574600129312954795149ad9008914d4c066a382e1c961ee2dc`.
Loader SHA-256:
`42eea031f2d7f4f584d7dd006a48743caf9f5497de56c68ab7bfd85630f6ffaa`.
WASM SHA-256 remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe source, descriptor, bytecode, and bundle identities remain attached
to browser reports. No GVM or external application source changed.
At E2.S4 completion, the next fixture story was E3.S1 (delivered below).

## E3.S1 — Dynamic SVG and the graph geometry slice

`EditableGraphRoot` renders four keyed nodes and three keyed paths from local
Ruby hashes. Its Move action replaces the node model; only the two adjacent
paths change. Reordering retains every keyed DOM node, removing/restoring an
edge recreates only that edge, and branch toggles recreate current geometry.
Marker references survive each operation. Pan exercises a compound transform;
`viewBox` and marker `refX` exercise case-sensitive SVG attributes. Geometry
uses native SVG templates and attribute bindings, with no raw HTML assembly.
Selection, pointer ownership, and bounded history remain subsequent stories.

E2.S1 already deferred SVG row slots and applied row values before insertion.
E3.S1 closes the ordinary-attribute gaps: the compiler stores dynamic SVG
attributes in inert markers, and the loader validates those markers against
the binding descriptors. It publishes the whole patch snapshot before
rendering; compound SVG values wait for all slots and write one complete
attribute. Unchanged values do not cause a DOM write. Conditional branches
apply available scalar SVG attributes while detached. Structural branches
still replay after insertion so table/select/SVG context and sibling removal
boundaries remain correct. Ordinary root geometry remains absent until its
initial patch; placeholders never become geometry values.

Compiler review also exposed Lexbor's local-name accessor lowering `viewBox`
and `refX`. The compiler now reads qualified names through the existing
Lexbor API, using a project-local FFI alias for its actual exported symbol.
No vendored library or copied SVG-name table is needed. Descriptors and inert
row payloads retain canonical names; HTML attributes and `foreignObject`
children retain their normal behavior. This does not introduce SVG custom
elements or a new contract for legacy namespaced attributes such as `xlink`.

`test/editable_graph_test.rb` supplies portable Ruby acceptance scenarios.
The framework driver additionally intercepts actual DOM insertion and
attribute writes synchronously: a MutationObserver alone could miss an
invalid intermediate value. It verifies initial geometry, numeric attributes,
namespace, marker targets, exactly two path writes on Move, none on reorder
or pan, surviving identities on delete/restore, three branch cycles, and a
fresh component mount. Both initially open and initially closed graphs run
in Chromium, Firefox, and WebKit. Console errors, page exceptions, and
`mochi:error` remain independently checked, including the existing table/
select/SVG context regression. Intentional negative probes keep their scoped
expectations.

Verification on 2026-11-13:

- `task specs`: **552 examples passed**, no failures/errors/pending. New
  descriptors cover ordinary/conditional/row SVG geometry, compound slots,
  canonical names, and HTML descendants of `foreignObject`.
- `task runtime:test`: **198 tests passed**, no skips. New checks observe
  complete writes across partial patch batches and conditional insertion,
  including a condition emitted before its geometry values.
- Final `task framework:e2e`: **345 checks passed** across Chromium, Firefox,
  WebKit: 285 main framework/UI checks (including 189 UI/workflow checks)
  plus 60 asset/install/evolved-feature checks. An earlier test incorrectly
  expected reconnecting the same host to reset state; the fresh-mount check
  now creates a new host, preserving the existing reconnect contract.
- `task gvm:test`: **215 cases / 20,943 assertions passed**, no skips/errors.
  No VM or external application source changed.
- Payload gate (`ruby scripts/payload_check.rb`): passed. Loader adds
  **1,578 raw / 327 gzip bytes**, becoming **221,136 / 46,901 bytes**.
  Core becomes **496,899 raw / 160,278 gzip bytes**; budgets rise by exactly
  that delta. WASM, JS glue, optional downloads, and capacities are unchanged.
- `task compile-time:test` passed. `task compile-time:framework`: all
  **15 builds passed**, **204.0–212.8 ms**, below the unchanged 1,000 ms limit.
  This isolated run followed other compiler uses; it does not prove a repair
  for the historical first-launch outlier.
- Crystal formatting, Ruby/JavaScript syntax, documentation links, and
  whitespace checks passed. Read-only context/review work found the SVG
  casing defect and verified its repair. No commits were made.

Compiler SHA-256:
`b3b9e200df4e4e9ae82c67d260e35fd98bb9aef88155de73d0d6da8e0a56edfd`.
Loader SHA-256:
`64e8852c2e712a02f0949500826d783a31fe46b606d5be353d962770fb0ae2e0`.
WASM SHA-256 remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe source, descriptor, bytecode, and bundle identities remain attached
to browser reports. At E3.S1 completion, E3.S2 was next (delivered below).

## E3.S2 — Explicit native event target and handler datasets

Native event normalization now exposes `target_dataset` and
`current_target_dataset`. The existing `dataset` remains the target snapshot.
The current target is the element bearing the bound handler, supplied by
Mochi's existing dispatch path; it is not the delegated shadow-root listener
and is not inferred from a nearest dataset-bearing ancestor. All maps use
string dataset values, DOM dataset key casing, and the existing internal
`mochi*` filter. The temporary JavaScript map has no prototype, so a literal
`data-__proto__` key stays plain data through JSON transport.

Snapshots are captured before queued Ruby delivery. Removing a descendant
after dispatch does not change its captured values; removing the bound node
before delivery suppresses that event. Open and closed shadow tests preserve
browser retargeting: outside the nested shadow root, the target map comes from
the child host and the current-target map comes from the bound outer element.
Composed-path entries stay label-only. Typed child events return their declared
payload before normalization and receive no injected native metadata.

The inspector now uses native table rows with a bound `select_record($event)`
handler and nested buttons/message labels. Keyboard activation of those buttons
still selects the row. The graph binds `select_node($event)` to each keyed SVG
group; circle and text descendants select the same stable node ID. Both read
`current_target_dataset` directly, without path scans or added selection IDs.
Ruby scenarios cover descendant selection after paging, geometry changes, and
branch recreation. Framework assertions also dispatch on the bound surface and
perform native mouse clicks on descendants.

The report-08 fixture checks both legacy and explicit target values separately
from handler identity. Target-only and handler-only 9,000-character padding
both exceed the existing **8,192-byte** JSON argument envelope. The VM rejects
them before the handler runs; framework assertions verify exact resource
counts, authored `select_row` location, profile fingerprint, unchanged call
count, and successful later clicks. Each expected negative diagnostic is scoped
to its failing operation. No capacity or VM change was needed.

Ruby graph scenarios exposed a test-runner omission: SVG elements have no
native `.click()` method. The runner now dispatches a bubbling, cancelable,
composed click for elements without that method, retaining native HTML click
activation. Separate native browser tests exposed WebKit driver bounding boxes
that omit SVG text x/baseline offsets. Those checks use the browser's actual
client rectangle, assert the point hits the label, and send real mouse input;
they do not force clicks or change application geometry.

Verification on 2026-11-13:

- `task runtime:test`: **201 tests passed**, no skips. New cases cover
  distinct datasets, internal filtering, special property names, snapshot
  timing, detached source/handler nodes, and open/closed shadow retargeting.
  Existing exact typed-child-payload assertions still pass.
- `task specs`: **552 examples passed**, no failures/errors/pending.
- Final `task framework:e2e`: **354 checks passed** across Chromium, Firefox,
  WebKit: 294 main framework/UI checks (including 198 UI/workflow checks)
  plus 60 asset/install/evolved-feature checks. The earlier WebKit native
  label test failed on driver coordinates; browser hit-tested coordinates
  now pass without forcing the event. SVG Ruby scenarios use the rebuilt
  compiler's embedded runner.
- `task gvm:test`: **215 cases / 20,943 assertions passed**, no skips/errors.
- Payload gate (`ruby scripts/payload_check.rb`): passed. Loader adds
  **203 raw / 49 gzip bytes**, becoming **221,339 / 46,950 bytes**. Core is
  **497,102 raw / 160,327 gzip bytes**. Baselines increase by exactly that
  delta; WASM, JS glue, optional downloads, and capacities are unchanged.
- `task compile-time:test` passed. `task compile-time:framework`: all
  **15 builds passed**, **206.5–214.8 ms**, below the unchanged 1,000 ms limit.
  This run followed other compiler uses; it makes no repair claim for the
  historical first-launch outlier.
- JavaScript/Ruby syntax, documentation links, and whitespace checks passed.
  Read-only context and final review found no remaining issues. No commits
  were made, and no GVM or external application source changed.

Compiler SHA-256:
`476ae7242ad0284ee04fe398d845e0efaf8c532d8bdcc9358049e8b6b7fc487c`.
Loader SHA-256:
`61cfe17dae6135d2caff66082fc90ede6f848a68d70b3029ec6269d7a103ac94`.
WASM SHA-256 remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe artifact identities remain attached to browser reports.
At E3.S2 completion, E3.S3 was next (delivered below).

## E3.S3 — Graph editing, bounded history, and pointer lifetime

`EditableGraphRoot` now adds/removes nodes, removes incident edges with a node,
and replays edits through ordinary Ruby snapshot history. Each snapshot copies
node/edge arrays and hashes plus selection, next-ID counter, and edge ordering.
Current model state is separate. Undo and redo retain **at most 40 snapshots
combined**; committing an edit trims the oldest history and clears redo. Undo
and redo transfer one current snapshot between stacks and restore a fresh
working model. Existing snapshots are never mutated or deep-copied as a whole
history. Root array replacement drives rendering without an epoch variable.
Pan and branch visibility are viewport state outside model history.

A keyed SVG group captures pointer input even when its circle/text receives
the press. The stable SVG ancestor handles movement and terminal events. The
fixture uses start-position plus client-coordinate deltas in its fixed 400×220
viewport; measurement/zoom remain E5. A gesture holds one temporary rollback
snapshot. Pointer-up applies the final delta and commits once if geometry
changed. Cancel/lost-capture restore the model without committing or clearing
redo. Return-to-origin and stationary gestures add no history. Model/history
actions and branch removal cancel first. The loader releases capture before
`unmounted`; the hook only clears Ruby gesture state.

The Ruby runner now observes actual capture ownership rather than assuming
that pointerdown's original descendant owns capture. It records capture events,
checks pending capture among retained path nodes, and can resolve a named-ref
owner in open shadow roots. Loss/cancel/release/unmount assertions use that
owner. A negative workflow test proves an active ancestor capture is detected
before the first movement, preventing false passing release assertions.

Ruby scenarios perform **45 edits**, check all **40 undo steps** back to edit 5,
then all **40 redo steps** back to edit 45 with exact node coordinates/radii,
labels, and connected paths. They cover new edits after undo, deterministic IDs,
node/edge restoration, cancellation with a pending redo branch, completed new
drags clearing redo, drag outside the canvas, repeated cancellation/loss, branch
removal, and unmount. Browser checks compare complete rendered snapshots and
mixed reorder/remove/restore/add history. A separate ownership audit repeats
mount/cancel/loss/branch removal/disposal and verifies zero captures, queued
pointer moves, or extra component/binding registrations after cleanup.

The graph uses the existing optional pointer capability. Inspector-only
rendering fetches neither graph descriptor/bytecode nor the pointer package or
adapter. First graph mount loads them; repeated mounts request each pointer
resource once. Production compiler, loader, VM, adapters, and capacities are
unchanged. Test-driver changes are embedded tooling only. Detailed graph and
initial-entry costs are recorded in [payload budgets](PAYLOAD_BUDGETS.md).

Verification on 2026-11-13:

- `task specs`: **552 examples passed**, no failures/errors/pending.
- `task runtime:test`: **201 tests passed**, no skips.
- Final `task framework:e2e`: **363 checks passed** across Chromium, Firefox,
  WebKit: 303 main framework/UI checks (including 207 UI/workflow checks)
  plus 60 asset/install/evolved-feature checks. An earlier browser audit put
  its mixed-edit sequence before an older-state assertion; correcting that
  test order preserved all exact state comparisons. An initial ownership
  probe assumed an already installed adapter registrar; it now observes the
  registrar's lazy creation without changing production behavior.
- `task gvm:test`: **215 cases / 20,943 assertions passed**, including the
  existing slicing regressions. No VM change was needed.
- Payload gate (`ruby scripts/payload_check.rb`): passed with **zero core
  growth**, unchanged capacities, and unchanged budget files. Core remains
  **497,102 raw / 160,327 gzip bytes**. Staged shared-fixture comparison against
  E3.S2 graph source shows **436 raw / 121 gzip bytes** of additional initial
  manifest metadata; every other initial file is byte-identical. The graph's
  four later files total **28,970 raw / 7,747 gzip bytes**, including the existing
  pointer package/adapter. They are not fetched for inspector-only rendering.
- `task compile-time:test` passed. `task compile-time:framework`: all
  **15 builds passed**, **128.3–213.7 ms**, below the unchanged 1,000 ms limit.
  This run followed other compiler uses and does not establish a repair for
  the historical first-launch outlier.
- Ruby/JavaScript syntax, documentation links, and whitespace checks passed.
  Read-only context and implementation review found no remaining issues.
  No commits were made; no production compiler/loader/VM/adapter or external
  application source changed.

Compiler SHA-256 (including the updated test runner):
`e7898da4d8d95a0498929faa1c7972182378bbafd34a7739b51495b059ad01c0`.
Loader SHA-256 remains
`61cfe17dae6135d2caff66082fc90ede6f848a68d70b3029ec6269d7a103ac94`.
WASM SHA-256 remains
`c87012d711bae6d099233f312dca2a248beda749cc13f1d5e9ef6be017589cf9`.
Per-probe artifact identities remain attached to browser reports.

## E4.S1 — explicit computed values and root-state invalidation

The Ruby contract is now
`computed :visible_rows, depends_on: [:@records, :@query, :@page, :@page_size]`.
Symbols beginning with `@` name state roots; other symbols name computed
methods. Dependencies are explicit, flattened and checked for unknown names
and cycles. Declaration order is independent of method evaluation order.
The compiler preserves authored method lines and removes declarations only
from Sorbet's isolated view. It checks visible reads, writes and effects through
component helpers, including helper defaults, while respecting lexical locals.

The VM stores one lazy result per component/method and invalidates it only
after a changed declared root write. Cache hits preserve the existing binding
read mask; two consumers share the same result. Nested computed methods retain
ordinary Ruby call order. Inherited computed methods remain guarded/cached;
an ordinary override replaces the inherited declaration. There is no additional
reactive scheduler or arbitrary dependency inference.

Root replacement is the published nested-state contract. In-place Ruby mutation
still works outside computed evaluation, but does not promise computed
invalidation. Reassigning the same collection is not replacement. Cached
collections should be treated as read-only inputs. The complete contract and
example appear in [Ruby surface](RUBY_SURFACE.md#explicit-computed-values).

Successful results are promoted into persistent state and marked through the
existing collector. Invalidation clears retained results; unmount removes
entries before collection. Failed evaluation/promotion never publishes a valid
cache. Component writes, retained collection mutation, native/host calls and
reentry fail before their effects. Fresh local collection construction remains
valid. Binding failures identify the authored computed method, discard the
patch batch, and recover after a valid input change.

The isolated [computed probe](../e2e/fixtures/ui_contracts/probes/12-computed/lib/ProbeRoot.rb)
uses two instances, three consumers, unrelated writes, root replacement, two
dependency changes before a flush, division failure/retry, indirect mutation
rejection, and unmount/remount. Browser tests build a temporary instrumented VM
to count actual evaluations; production source/artifacts have no counter or
telemetry. The inspector/graph migration remains E4.S2.

Resource accounting: cache entries have their own table bounded by the profile's
`bindings` limit; result graphs consume existing persistent arenas. No
application arena or total-memory maximum was increased. Generated Goose
storage grows from 47 to 50 regions; the profile identity and conservative
minimum-memory estimate include this cost. Current capacity fingerprint:
`8b48ea60102176d9c990ae775ae77eb368dcbbe43cb0638708f8383fe12d8731`.
Detailed byte deltas and exact budget refresh are in
[payload budgets](PAYLOAD_BUDGETS.md#explicit-computed-values-e4s1-historical-delta).

Validation on 2026-11-13:

- Compiler: **564 examples passed**, covering declaration syntax, transitive roots, unknown names,
  cycles, purity, helper defaults, lexical scopes and preserved source lines.
- Goose: **222 cases / 21,014 assertions passed**. Seven computed tests cover
  shared bindings, separate instances, forced GC with nested arrays/hashes,
  inheritance, reentry/effects, failed promotion, bounded cache entries,
  invalid metadata and reclamation after disposal.
- Runtime: **202 tests passed**, including computed source attribution.
- Full framework browser gate: **369 checks passed** across Chromium, Firefox,
  and WebKit (309 main checks plus 60 asset/install/evolved checks).
- Final computed browser/typecheck probe: **six checks passed** after the last
  compiler validation change. The separate tiny-profile capacity suite needed
  its unused file-chunk reservation lowered to 2,048 bytes to remain valid
  under its existing 8,192-byte scratch limit; no tested bound was enlarged.
  All **33 capacity checks passed** across Chromium, Firefox and WebKit.
- Compile-time unit gate passes; all **15** framework builds pass in
  **136.9–151.3 ms**, below the unchanged 1,000 ms limit. This follows prior
  compiler runs and does not establish a historical first-launch-outlier fix.
- Payload membership, determinism and refreshed exact ceilings pass. Core is
  **504,586 raw / 163,563 gzip bytes**, up **7,484 / 3,236**. Later optional
  formatting resources remain unchanged. Default minimum-memory estimate is
  **83,230,720 bytes**, below the unchanged **100,663,296-byte** maximum.
- Goose formatting and both repository whitespace checks pass. Context and
  read-only implementation review informed inheritance, lexical-scope,
  helper-default and error-unwind regressions. No commits were made.

Compiler SHA-256:
`0a9721fdb60947e20aadd897bfe35c626d1e64fdd8c36bb9a22acb941f45f0e9`.
Loader SHA-256:
`c74ac792cb25dcfb4064fdae284350b32e938e014e5ae5943dde99d908fa0aab`.
Production WASM SHA-256:
`89c1f41e995a6af60c897020d81d3580b1e09451706d30a04be375004ca3418c`.


## E4.S2 — computed inspector and graph projections

The inspector now retains **480 records**, including nested attribute arrays,
and renders only **12 rows**. Separate computed values own filtering, visible
page, selected record, and detail projections. Detail bindings share one
lookup. Literal input is bound once before page reset; no parsing loop or
serialized record format is used. Initialization publishes each completed
record into durable state before constructing the next.

Append replaces the root and retains the newest 480 records. Filtering keeps
selection even when it is outside the visible result. Explicit removal and
retention eviction clear selected details. Removal clamps the current page.
Ruby scenarios visit every ID across forty pages, inspect nested values,
exercise empty/last filtered pages, and repeat append/removal actions.

The graph computes edge paths from node/edge roots. Existing immutable edits,
dragging, forty-snapshot history, undo, and redo now drive that projection.
Pan and branch toggles reuse it. There are no epochs, manual projection caches,
feed timers, indexes, or virtual scrolling. A temporary instrumented VM counts
individual computed evaluations: paging only slices, detail toggles do not
filter or scan selection, root replacement refreshes each affected projection
once, and graph edits/undo/redo refresh geometry once. Production has no counters.

This workload reproduced a default-browser VM defect: persistent growable
tables outgrew their physical Goose regions before the configured state limit.
Native execution passed; 360 rich browser records mounted, but 480 stalled.
Backing the persistent arenas and GC tables at their declared capacities fixes
the overrun. The checked WASM build also lowers generated default-zero array
initialization directly into static storage, avoiding oversized temporary copies.
Unexpected generated initialization fails the build. Fresh promotion no longer
scans published roots for each field; publication and later alias mutations
retain their notifications. Native real-bytecode and browser fixtures cover
the complete record shape. See [capacity details](CAPACITY_CONTRACT.md).

Validation on 2026-11-14:

- Compiler: **564 examples**, all passed, including isolated custom-profile
  builds, initialization layout checks, and embedded profile identity.
- GVM: **226 cases / 21,037 assertions**, all passed; initialization-lowering
  checks rerun after the final validation guard. Goose formatting passed.
- Runtime: **202 tests**, all passed.
- Framework browsers: **312 main + 60 asset/install/evolved checks**, all
  passed across Chromium, Firefox, and WebKit. Capacity boundaries: **33 passed**.
  The matrix includes all authored inspector/graph scenarios and projection counts.
- Payload determinism, membership, and tightened ceilings passed. Core is
  **497,681 raw / 161,170 gzip bytes**, down **6,905 / 2,393** from E4.S1.
- Compile-time rejection test passed; all 15 minimal cold/warm/edit builds
  were **145.1–177.8 ms**, below the strict 1,000 ms limit.

Application capacities and the 96 MiB maximum remain unchanged. Correct backing
raises measured initialized WASM linear memory from 66,453,504 to 80,084,992
bytes. The corrected estimate is 82,313,216 bytes with 40 Goose regions.
This does not establish that arbitrary 480-record shapes fit, or close E4.S3's
three-fixture capacity/lifecycle work. [Payload evidence](PAYLOAD_BUDGETS.md)
records both download and memory costs. No commits were made.

Production WASM SHA-256:
`d00028ccb934321f36835354b94de14177e832ce14576f920f5f29b493deafc7`.
Default capacity profile:
`4c12f87f5b1adbd1b7165dd6e2c0ff988d982c63c46baaa6b80e3984a992f7cf`.


## E4.S3 — capacity failure isolation and lifecycle reuse

The standalone capacity suite now forces computed scratch-object/byte failure,
nested computed-entry exhaustion, and persistent-byte pressure under a small
compiled profile. It verifies the resource and requested/used/limit counts,
profile fingerprint, and exact authored method line. Two output bindings remain
unchanged after rejection, and queued storage commands remain absent both
immediately and after later successful work. An independent component and a
smaller operation still work after each failure.

Recovery deliberately exposes the status written before failure and, for state
pressure, the positive retained-record count. These tests preserve the existing
nontransactional Ruby-state contract. Six failing computed mounts under a
four-entry cache bound release partial caches/bindings before a valid mount;
the earlier successful binding is not partially published.

`gvm_ui_capacity_lifecycle.spec.ts` runs the actual inspector, graph, and form
under reduced scratch/state/binding/component bounds. Each browser executes
100 page/filter/append, graph edit/undo/redo, and form close/reopen cycles, then
100 complete mount/disposal cycles. Inspector retention stays at 480 with 12
visible rows, graph history trims at 40, recreated editor drafts reset, and
subscriptions/bindings/live allocations/reusable bytes return to baseline.
The native suite adds 100 computed replacement/error/recovery/disposal cycles
while a second instance's cached graph stays rooted. No new diagnostics UI,
profiler, telemetry, benchmark, capacity defaults, or memory ceilings were added.

One defect was reproduced and fixed: cache-entry allocation could fail before
the computed method had a frame, attributing exhaustion to its caller. GVM now
captures the rejected method, existing binding ID, and allocation details at
that point. The browser regression rejects caller-line attribution; native
coverage checks the computed marker, method symbol, and capacity resource.

Validation on 2026-11-14:

- **227 GVM cases / 22,444 assertions**, all passed; Goose formatting passed.
- **564 compiler examples** and **202 runtime tests**, all passed.
- **423 browser checks** across Chromium, Firefox, and WebKit: 363 main
  (including 48 capacity cases and three 100-cycle cases), plus 60 asset/install
  checks. Final failed-mount and delayed-command assertions rerun separately.
- Payload determinism, membership, and exact ceilings passed. Core is
  **497,765 raw / 161,181 gzip bytes**; the source-attribution fix costs
  **84 raw / 11 gzip bytes**. Loader, glue, capacity profile, and arena limits
  remain unchanged. See [payload accounting](PAYLOAD_BUDGETS.md).
- Compile-time rejection check passed; all 15 minimal builds were
  **146.5–253.3 ms**, below the strict 1,000 ms limit.

Both capacity suites are included in `framework:e2e` and `framework:ui`.
Individual UI targets include the shared lifecycle run. Exact profiles and
recovery semantics are documented in [capacity contracts](CAPACITY_CONTRACT.md).
No commits were made.

Production WASM SHA-256:
`9844dd68d1836391229ed39466c33b128e10595ec46f9fa02f6068d4184bed93`.

## E5.S1 — optional static-ref geometry and fitted graph

`MochiLayout.measure`, `observe`, and `cancel` use the existing host-capability
ABI. The compiler follows reachable helpers to include the optional Ruby
package and adapter; minimal applications omit both. The graph mounts its
adapter lazily, and repeated mount/disposal cycles fetch it only once.

Geometry is plain numeric viewport-relative CSS border-box data. The adapter
coalesces resize notifications, reads each target once before callbacks, and
suppresses unchanged sizes. Requests and observations are bounded by the
existing binding capacity. Owner generation and target identity guard every
delivery; cancellation, branch removal, and unmount release work. Initial
frame delivery consumes its request synchronously, so another callback can
cancel a later measurement in the same batch. A completed one-shot releases
capacity before its callback can request another measurement.

The shared loader now runs adapter reconciliation after adapters are installed
and recreates its observer on every mount. This also preserves pointer cleanup
when the same custom element reconnects. Errors in one adapter's disposal do
not skip VM cleanup.

Fit graph computes circles and fixed-monospace label bounds in Ruby and fits
with 24 CSS pixels of padding. Browser geometry assertions cover both enlarged
and reduced containers, fit-scaled dragging, explicit cancellation, and three
fresh mounts. Zero/hidden dimensions, insufficient padding space, and an empty
model have explicit statuses and finite coordinates. Model undo history remains
independent of viewport framing. Dynamic row refs and per-node DOM measurement
remain deferred. See [layout contracts](LAYOUT_CONTRACT.md).

Validation on 2026-11-14:

- **565 compiler examples**, **213 runtime tests**, and **429 browser checks**
  passed (369 main plus 60 asset/install, across Chromium, Firefox, and WebKit).
  All 39 graph and 100-cycle lifecycle checks passed again after delivery-race
  fixes; same-element reconciliation also has a loader regression.
- Payload determinism, membership, and exact ceilings passed. Core is
  **499,006 raw / 161,392 gzip bytes**, an explicit loader increase of
  **1,241 raw / 211 gzip bytes** against E4.S3. No WASM, glue, capacity-profile,
  or memory-limit changes belong to this story.
- Optional layout adapter: **5,997 raw / 1,855 gzip bytes**. Ruby package:
  **468 raw / 275 gzip bytes**. Combined feature code is **6,465 / 2,130**,
  excluding component-specific bytecode, descriptors, and manifest metadata.
  These files do not appear in the unused minimal application.

Compile-time rejection checks passed. After compiler regeneration, one initial
cold invocation took 1,432.3 ms and failed the strict 1,000 ms gate; the other
14 took 135.6–147.8 ms. An unchanged full rerun passed all 15 at 137.7–142.8 ms.
The outlier is retained here; no timing threshold was relaxed.

## E5.S2 — raw wheel input, owned prevention, and anchored zoom

Wheel events expose raw `delta_x`, `delta_y`, `delta_z`, and `delta_mode` with
zero defaults. Existing `.prevent`, `.stop`, and `.self` declarations run in
the native listener; no compiler syntax or application JavaScript was added.
Actual-target non-passive listeners cover conditional/keyed regions and are
removed on branch disposal or unmount. Native Chromium/WebKit tests reproduced
scrolling with shadow-root delegation and passed after binding real regions.

One scheduled frame sums each target's deltas in three separate unit buckets,
with latest-anchor metadata. Delivery checks the owning mount and target again
at Ruby entry. Regressions cover retargeted composed `.self` events, targets
moved into another connected root, stale frames, and remount without duplicate
listeners. The old missing-delta probe now requires `4:12:0:0`.

Graph Ruby converts lines to 16 CSS pixels and pages to measured height, then
changes scale by `-pixels / 500`, clamped to 0.25–4. Translation preserves the
point beneath the latest anchor. One geometry read serves an accumulated zoom
batch, including mixed modes; fresh viewport origin remains correct after
page scrolling. New drags discard pending zoom, while wheel input cancels an
existing drag. Fit/close/stop/unmount clear pending intent. Browser checks use
0.02 CSS pixel anchor tolerance, real wheel scrolling inside/outside the graph,
both scale limits, and pointer drag after zoom. See [wheel contracts](WHEEL_CONTRACT.md).

Validation on 2026-11-14:

- **565 compiler examples** and **214 runtime tests** passed.
- **435 browser checks** passed across Chromium, Firefox, and WebKit (375 main
  plus 60 asset/install). All **45 graph/lifecycle checks** passed again after
  adding the pending-zoom/new-drag regression.
- Payload determinism, membership, and exact ceilings passed. Core measures
  **503,755 raw / 162,460 gzip bytes**, a loader increase of **4,749 / 1,068**.
  WASM, optional layout code, capacity profile, and memory limits are unchanged.
- All 15 minimal compile-time checks passed at **135.8–142.0 ms**, below the
  strict 1,000 ms limit. No new benchmark, telemetry, or capacity knob was added.

## E5.S3 — optional mount-owned shortcuts

`MochiShortcuts.register(key, callback, options)` returns an Integer cleanup
token through the existing host ABI; `cancel(token)` cancels only that owner's
current mount. Successful registration does not invoke the action. Matching
keys and registration errors use the normal `ok/value/error` callback envelope.
No GVM changes or Ruby test-runner extensions were needed.

The optional adapter strictly matches modifiers, normalizes single-letter key
case, ignores editable paths and repeats by default, and always ignores
composition. A composed-path check finds component ownership across shadow
roots. The newest active application owner suppresses lower shortcut scopes;
only one eligible match runs and declared prevention happens synchronously.
Registrations are bounded by existing binding capacity and removed on disposal.

An optional static `active_ref` makes scope activation follow its DOM region.
A missing ref deactivates without canceling the token; replacement/reactivation
updates precedence. Keydown rechecks ownership/ref presence before dispatch,
so neither branch-observer timing nor old mount generations can expose stale
shortcuts. Graph Ctrl/Meta+Z and Shift+Z operate while graph scope has focus;
its text input retains ordinary editing. Form Escape opts into editable targets,
closes through nested editor shadows, and restores captured opener focus.
Initially open forms retain the explicit toggle fallback.

The full matrix exposed a race in an intermediate conditional shortcut child:
the dialog could receive focus before that child registered its modal scope.
Binding activation directly to the parent-owned dialog ref fixes this and
handles externally updated `open` props without additional lifecycle hooks.
Ruby scenarios and native browser checks cover focus, precedence, editing,
repeated mount/disposal, one-time lazy loading, and unused-package omission.
See [shortcut contracts](SHORTCUT_CONTRACT.md).

Validation on 2026-11-14:

- **566 compiler examples** and **221 runtime tests** passed.
- **441 browser checks** passed across Chromium, Firefox, and WebKit: 381 main
  (including the 100-cycle fixture lifecycle checks), plus 60 asset/install.
  Final run uses ref-based activation; no failures or skipped cases.
- Payload determinism, membership, and exact ceilings passed. Core is
  **503,961 raw / 162,503 gzip bytes**, a shared loader increase of **206 / 43**.
  WASM, glue, memory limits, and capacity defaults remain unchanged.
- Optional adapter: **6,888 raw / 2,161 gzip bytes**; Ruby package:
  **391 raw / 280 gzip bytes**. Combined optional code is **7,279 / 2,441**,
  excluding consuming component code and manifest/descriptor metadata.
- All 15 minimal compile-time checks passed at **133.3–221.5 ms**, below the
  strict 1,000 ms gate. No new telemetry, benchmark, or capacity controls.

## E6.S1 — bounded optional JSON

`require 'json'`, `JSON.parse`, and `JSON.generate` select a **271 raw / 197 gzip
byte** Ruby package. The compiler resolves local imports before its built-in
fallback. Top-level static imports are removed after dependency resolution,
preserving source positions; browser integration caught the previously emitted
runtime `require` call. Helpers inherit normal package reachability. Unrelated
apps omit the JSON package; no JSON JavaScript adapter exists.

Pure VM primitives reuse JSON parsing and escaping with a strict document mode:
transport marker hashes stay ordinary data, integers remain signed64 without
passing through JavaScript numbers, and UTF-8 is validated. Generation rejects
non-string keys, unsupported objects, non-finite floats, and ancestor cycles
while allowing shared acyclic values. Limits are 48,000 document bytes and 16
containers; existing arena capacities can reject a smaller node-heavy document.
Duplicate keys are last-value-wins. Errors publish no successful partial result
and retain Ruby source context; later valid operations succeed. See the
[complete JSON contract](RUBY_SURFACE.md#optional-json).

Inspector Ruby tests parse a small nested sample and round-trip only the selected
record, preserving the structured 480-record collection and 12-row page. A
separate file contract uses existing bounded `MochiFiles.read_text`, verifies
exact integers/Unicode, rejects oversized input, then reads a valid next file.
No inspector import UI or monolithic multi-megabyte String was added.

The shared codec is an explicit core cost: **2,823 raw / 1,290 gzip bytes** in
WASM. Loader/glue and capacity defaults are unchanged. Core is now **506,784 /
163,793**, with WASM **215,773 / 97,810**. Exact payload ceilings increase only
by that measured delta; optional feature-later files remain unchanged.

Validation on 2026-11-14:

- **570 compiler examples**, **235 Goose cases / 22,551 assertions**, and
  **221 runtime tests** passed. Goose formatting and Ruby fixture typechecking
  passed. JSON uses a module, matching Sorbet's standard-library declaration.
- **447 browser checks** passed across Chromium, Firefox, and WebKit: 387 main
  (including 100-cycle lifecycle checks) plus 60 asset/install. JSON error tests
  preserve output after rejection, recover on a valid next call, and identify
  the authored method/source alongside the JSON VM method.
- Payload membership, determinism, and exact ceilings passed. All 15 minimal
  compile-time checks passed at **136.0–149.2 ms**, below the strict 1,000 ms gate.

## E6.S2 — optional wall clock and timestamp contract

`Time.now`, `Time.at(seconds)`, `to_i`, `to_f`, and `utc` supply a small UTC
instant surface. Numeric Unix seconds stay exact as Integers or preserve their
binary64 Float value, within ±8,640,000,000,000 seconds. Integer conversion
floors before the epoch; UTC conversion returns the same object. The wall-clock
adapter returns checked integer milliseconds, converted once to seconds by
Ruby. It schedules nothing and retains no owner resources. Calendar APIs,
Time.new, Date, parsing, local-zone state, and subsecond argument overloads stay
unsupported with source-located errors. See the
[timestamp contract](RUBY_SURFACE.md#optional-wall-clock-and-unix-timestamps).

A narrow pure VM constructor creates ordinary state instances because this VM
does not expose general Ruby object construction. It preserves normal ivar,
dispatch, and GC behavior without registering components or extending capacity
profiles. `Time.at` works in computed getters; the impure `Time.now` host read
is rejected there. Goose tests retain/reclaim Time values through 100 GC cycles.

`MochiFormat.timestamp` has an explicit seconds boundary, converting to Date's
millisecond display precision. Existing ISO/date-only formatting stays intact.
The inspector sorts raw integer millisecond instants, switches chronological
direction, and displays selected records in explicit en-GB UTC/Tokyo zones.
Changing display zone preserves ordering and selection. Tests use fixed record
times and injected/fixed clocks, including pre-epoch and initialization reads.
No test depends on today's date; existing monotonic elapsed timing is unchanged.

Clock code is optional: **1,219 raw / 585 gzip bytes** for `mochi-time.js` plus
**444 / 285** for Ruby Time. Browser checks prove omission from unrelated apps,
one adapter request across remounts, ready-before-initialize behavior, and
source-located failure/recovery. Formatting is a separate optional capability.

The shared constructor and native bridges cost **870 raw / 446 gzip bytes** in
WASM; loader/glue and capacity defaults are unchanged. Core is **507,654 /
164,239**, WASM **216,643 / 98,256**. Optional formatting's timestamp path adds
**1,045 / 220** across adapter and Ruby code, reflected only in feature-later
payload. Exact ceilings track these measured changes.

Validation on 2026-11-14:

- **571 compiler examples**, **238 Goose cases / 22,996 assertions**, and
  **226 runtime tests** passed. Goose formatting and fixture Ruby typechecking
  passed; existing ISO/date-only formatting coverage remains green.
- **453 browser checks** passed across Chromium, Firefox, and WebKit: 393 main
  (including the 100-cycle lifecycle checks) plus 60 asset/install checks.
- Payload membership, determinism, and exact ceilings passed. All 15 minimal
  compile-time checks passed at **135.6–157.3 ms**, below the strict 1,000 ms gate.

## E6.S3 — bounded downloads and inspector exports

`MochiDownload.save(filename, content_type, content)` accepts a String or up to
1,024 binary String parts. A synchronous native byte-view bridge preserves
arbitrary bytes and current user activation without routing through bounded
JSON transport or joining all output into a scratch String. The Ruby package
and Blob/URL adapter remain optional; the loader resolves both before rendering
export controls. A delayed-adapter browser check locks down that readiness.

Inspector exports every row in the current filtered set and sort order, not
only the visible page. JSONL uses `JSON.generate` per record. CSV quotes all
data fields and doubles quotes, preserving Unicode, commas, embedded newlines,
and raw millisecond timestamps. Empty filters produce empty JSONL/header-only
CSV. Ruby scenarios compare actual downloaded bytes against independent MRI
JSON/CSV output for all 480 rows, filtered/reversed rows, and special/empty data.

The optional adapter rejects metadata, activation, stale-owner, per-file byte,
pending-byte, and URL-count violations before handoff. Failure releases any
allocated URL immediately. Accepted URLs survive component disposal and expire
after a 30-second lease; timer throttling may delay release, but retention stays
bounded. Browser checks verify exact binary bytes, Unicode filenames, MIME,
failure/recovery, repeated exports, and disposal/expiry. Runtime tests cover
injected construction/append/click failures and 50 release/reuse cycles.

Ruby test authors use `download` and `assert_download filename:, bytes:`.
Assertions inspect suggested filenames and exact artifact bytes; canonical
Unicode filename equivalence accommodates WebKit/macOS normalization. Errors
keep the authored test location. A discovered helper/component name collision
also required class-qualified runtime source mapping: `MochiDownload#save`
must not be attributed to an unrelated component `save` method.

See [the complete download contract](DOWNLOAD_CONTRACT.md). Save pickers,
filesystem writes, streaming exports, and completion/cancellation after browser
handoff are outside this bounded API. No application JavaScript is required.

Optional download code is **4,189 raw / 1,792 gzip bytes**. Shared bridge,
ownership, readiness, and source-mapping changes add **3,049 / 964** to core, now
**510,703 / 165,203**. Exact payload budgets track these measured changes;
default capacity profiles and the formatting feature-later payload are unchanged.

Validation on 2026-11-14:

- **572 compiler examples**, **239 Goose cases / 23,003 assertions**, and
  **232 runtime tests** passed. Goose/Crystal formatting and Ruby typechecking
  passed for the shared fixtures and binary download probe.
- **459 browser checks** passed across Chromium, Firefox, and WebKit: 399
  main checks (including 100-cycle lifecycle checks) plus 60 asset/install
  checks. Download checks cover actual artifacts and delayed capability readiness.
- Payload membership, determinism, and exact ceilings passed. All 15 minimal
  compile-time checks passed at **144.5–169.4 ms**, below the strict 1,000 ms
  gate; the gate's own failure test passed too.

## Final verification (E7.S2)

Verified on 2026-11-14 after the documentation and generated starter changes:

- **573 compiler examples** and **232 runtime tests** passed. The new compiler
  regression reads the published capacity example and checks its normalized
  values/fingerprint against the default profile; the stale 50-region value is
  corrected to 40. Crystal formatting and change whitespace checks passed.
- **459 browser checks** passed on Chromium, Firefox and WebKit: 399 main
  framework/UI checks plus 60 asset/install checks. This includes all three
  completed Ruby fixture suites, intentional failure/recovery probes,
  100-cycle lifecycle coverage, and generated starter installation/build/tests.
- Shared fixture Ruby typechecking passed. The published README CSS excerpt
  was inserted into a freshly generated starter with `lib/styles/` fragments,
  then built/typechecked using the actual `docs/capacity.example.json`.
- Local documentation file/heading links passed validation. All twelve new
  reports retain source-backed dispositions, distinct from the older inventory.
- Payload membership, determinism and existing ceilings passed unchanged:
  core **510,703 raw / 165,203 gzip**, minimal initial **514,381 / 166,908**.
  All 15 minimal compile-time checks passed at **146.3–165.2 ms**, below
  1,000 ms; the gate's rejection test passed too.

Source baseline: Mochi `2226fb67dfc08fa8812610b5bf943fe4f60ce8e1` plus this
uncommitted E7.S2 change; unchanged GVM `f215374734f7aea014bb2bdd48a47b688b496d79`.
Compiler SHA-256: `4f8563de87ed5139aaf3df77aabdf2970792a84595e44c33d28f67e823e3c963`.
The actual typechecked fixture bundle contains loader
`dd9ca7099c6ef284e020463f386202b8f87615a41647fd913ae9cc944f13bb91`
and WASM `1327c9aadd23e7225c033927e72f7ef4562bfe5669e04bd11fcf57d4f8b87f98`,
with unchanged capacity fingerprint
`4c12f87f5b1adbd1b7165dd6e2c0ff988d982c63c46baaa6b80e3984a992f7cf`.

Only Mochi guidance, its generated starter text, and the capacity-example
regression changed in this story. No VM/runtime feature, default limit, payload
budget, product checkout, benchmark, telemetry or feature flag changed. No
commits were made. This is the final story in the plan; retained deferrals above
are explicit scope boundaries, not claims of implemented behavior.

## Completion audit (al-dente)

Verified all 21 stories and 87 acceptance criteria on 2026-11-14. One small
diagnostic gap was reproduced and fixed: a failed `MochiDownload.save` call
during `mounted` could report an unrelated component `save` method's line
after mount rollback cleared VM error state. The loader now retains the
lifecycle caller and qualifies parsed method names by component class.
Initializer and mounted regressions cover source attribution and cleanup.
No larger unimplemented story gap was identified within the published scope.

- The fresh baseline `task check` passed: **573 compiler examples**, **239
  Goose cases / 23,003 assertions**, **232 runtime tests**, and **459 browser
  checks**, plus payload and compile-time gates.
- After the correction, **234 runtime tests** and **462 browser checks**
  passed: 402 main checks plus 60 asset/install checks across Chromium,
  Firefox and WebKit. The new browser case checks both lifecycle failures.
- Payload membership, determinism and exact ceilings passed. The correction
  costs **364 raw / 90 gzip bytes** in the loader: core is now **511,067 raw /
  165,293 gzip**, minimal initial **514,745 / 166,998**. WASM, glue, optional
  packages and default capacities are unchanged. See
  [payload budgets](PAYLOAD_BUDGETS.md#lifecycle-source-diagnostics-completion-audit).
- All 15 minimal compile-time checks passed at **132.7–227.6 ms**, below
  1,000 ms. Goose formatting and change whitespace checks passed.

Audit baseline: Mochi `42bf6791ffe44ed9a89a9f974ea0ce82c69c855e` plus this
uncommitted correction; GVM remains `f215374734f7aea014bb2bdd48a47b688b496d79`.
The compiler and VM implementation did not change during the audit. The
retained boundaries above remain explicit; this review does not establish
full Ruby compatibility or reproduce every historical product workload.
