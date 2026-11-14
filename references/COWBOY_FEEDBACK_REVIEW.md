# Cowboy port feedback: verified findings

Reviewed 2026-11-14 against Mochi commit `97b94f76bd2d110767ccff6f43d35b6466c9f673`, with the compiler rebuilt from source. Input: the six Markdown files in `~/repos/sencha/feedback`, plus its retained `frontend-mochi` implementation. Cowboy is evidence only; no product files or workarounds were changed.

## Reproduce

- `task build`
- `cd e2e && npx playwright test gvm_feedback_review --reporter=line`
- From the repository root, with Ruby 2.7+: `ruby scripts/research_cowboy_feedback.rb`
- `node --test runtime/test/mochi-pointer.test.js`

On this machine the MRI oracle used `/opt/homebrew/opt/ruby/bin/ruby` (4.0.9); the system Ruby 2.6 cannot parse beginless ranges. The research script prints observations, including known failures, and deliberately does not treat those failures as desired behavior. Generated projects are temporary and require no Cowboy checkout. The browser fixture is in `e2e/fixtures/feedback_review`.

Results: **15 browser tests passed** (five scenarios in Chromium, Firefox, and WebKit), **6 pointer adapter tests passed**, and the research script recorded **17 compiler cases and 11 Ruby surface cases**. Runtime Ruby failures were checked in all three engines; rejected syntax never reaches a browser. The script's compiler hash, MRI values, exits, and diagnostic excerpts are retained in [raw observations](evidence/cowboy-feedback-2026-11-14.json). Temporary paths in that evidence are normalized.

“Dismissed” below means the proposed general limitation is contradicted by current evidence. It does not establish what happened in an unavailable earlier implementation. No framework fixes are included in this investigation.

## Confirmed limitations and defects

| Feedback | Finding | Evidence / consequence |
| --- | --- | --- |
| Compiler 1: `OP_TCLASS` at component size threshold | Confirmed; authored method count is not the actual limit. | 256 trivial methods compile; 257 fail. 118 methods plus 130 bindings compile; 118 plus 140 bindings fail. |
| Events 1: unbraced child event handler is silently literal | Confirmed. | `on:action="handle"` compiles unchanged, without a handler descriptor. Add source-located validation rather than silently accepting it. |
| Compiler 3: `Array#unshift` unavailable | Confirmed. | MRI returns `1,2,3`; Mochi reports `unknown method` in all engines. |
| Compiler 4: collection type checks fail | Confirmed and broader than reported. | Array reports `unknown method`; Hash, Integer, and Float report unknown component-qualified classes. All four fail in all engines. |
| Compiler 11: Range slicing limited | Confirmed, with a precise boundary. | Inclusive, exclusive, computed-end, negative-end, beginless, endless, and stored Range forms are rejected as `OP_RANGE_INC/EXC`. `a[start, length]` works and matches MRI in all engines. Range arguments are explicitly outside the current Ruby surface contract. |
| Components 5: mixed `Mochi.raw` introduces a wrapper | Confirmed. | Inline SVG's parent is a generated `SPAN` in all engines. Direct-child/flex-item assumptions can therefore change. This is observable layout behavior, not evidence that the SVG is missing. |
| Error locations obscure failing Ruby helper | Independently confirmed. | Type-check and unshift probes fail through `__mochi_bind_0` at class line 1 instead of naming the helper and operation. The large binding-heavy class points past its authored source. |
| Components 2/6: reusable content projection | Remains outside the supported contract. | Existing documentation explicitly excludes slots. This review does not establish a Ruby content ownership, event, or lifecycle contract for native `<slot>` markup. |

### Why large components fail

The retained local mruby source, `build_wasm/mruby/src/mrbgems/mruby-compiler/core/codegen.c:5002`, selects fused `OP_TDEF` when the method's child IREP index is at most `0xff`. Above that it emits `OP_TCLASS`, `OP_METHOD`, and `OP_DEF`. Mochi's `compiler/src/gvm/rite_verifier.cr` accepts the fused opcode but rejects the fallback sequence.

Thus adding a template binding can trigger failure without adding an authored method: Mochi generates Ruby getter/event methods. The two binding-count probes demonstrate this independently of Cowboy. This is a bytecode compatibility boundary, not proof of a per-method byte-size limit or a universal 118-method cap. Merely allowing the opcodes in the verifier would not establish VM support; any repair needs execution coverage as well as compilation and payload accounting.

## General restrictions contradicted by browser evidence

| Feedback | Disposition | What was exercised |
| --- | --- | --- |
| Events 1: only one event per child | Dismissed as a general limitation. | `action` and `change` both connected to the same child. |
| Events 2: `action` reserved; `change` unreliable | Dismissed as a blanket name restriction. | Both emitted and delivered typed payloads, including after repeated remounts. |
| Compiler 6: child props inside each do not work | Dismissed as a general limitation. | String and Hash props inside two nested keyed loops under a conditional; replacement, reordering, and delayed child descriptors. |
| Compiler 7: remount loses child events | Not reproduced in the tested contexts. | Three render cycles with both child events, value replacement, and fresh conditional mounts. |
| Events 3: row dragstart is not registered | Dismissed for the tested nested case. | The only drag binding is on the nested row button. Dispatch populates the native DataTransfer and updates Ruby state; no ancestor listener exists. This tests event registration/transfer, not OS drag initiation. |
| Compiler 2 / Components 1: `%Q` raw helper produces empty modal | Not reproduced from the supplied shape or richer conditional context. | Raw helper inside the modal branch, literal braces, Ruby interpolation, nested rows, updates, and remounts. Original failing helper is absent, so other shapes remain possible. |
| Events 7 / Testing 3: `.click()` needs replacement with composed MouseEvent | Dismissed as a general rule. | `HTMLElement.click()`, real button clicks, and real nested-span clicks deliver the child event. Correct shadow-root selection and mount readiness still matter. |
| Runtime 1: no timers | Dismissed at runtime; discovery/documentation gap remains. | `Mochi.every`, `Mochi.cancel_timer`, and automatic timer removal on unmount work in every engine. Earlier investigation also exercised `Mochi.after` in Chromium. This does not promise precise background-tab scheduling or establish typechecker support. |
| Runtime 4: no persistence helper | Dismissed for bounded String persistence. | `Mochi.storage_set/get` survive a browser reload in every engine. This does not prove that a whole Cowboy workspace fits storage command limits. |
| Runtime 5: `display: contents` cannot own component shortcuts | Dismissed; scope follows event ancestry. | Default component scope fires with focus inside the display-contents owner, and does not fire from an outside sibling. An empty bridge is not an ancestor of a sibling canvas's focused control. No automatic parent/application fallback is warranted. |
| Components 4: missing CSS import may fail silently | Missing-file case dismissed. | Compilation fails with component, import, and resolved-path information. An existing but unintended stylesheet is a different case. |

## Layout, readiness, and event semantics

**Runtime 2: initial layout width.** The delayed-child fixture deterministically measures 800px while the child descriptor and its 200px host CSS are withheld. The real `getBoundingClientRect()` is also 800px. After releasing the descriptor, both DOM and Ruby report 600px. A measurement is a current geometry snapshot, not a promise that descendant resources have finished loading. This reproduces the transient-width phenomenon without a stale adapter reading; it does not establish the cause of every measurement in Cowboy. Avoid a “measure twice” guarantee: two frames may both precede the child load.

**Components 7 / Testing 1: late children.** Delaying a descriptor leaves the parent interactive. Updating row props during the delay still produces the latest values when the child mounts, and the first subsequent interaction succeeds. Lazy children require readiness-aware testing. The historical claim of several seconds on an otherwise ordinary local load remains unverified: no timing trace or request log was supplied.

**Events 4–6 / Testing 4/6:** dataset camelCase and shadow traversal are real browser-facing contracts. A non-composed drag event works inside its owner's shadow root in the retained probe; `composed: true` is needed only when the intended listener is across a shadow boundary. It is not a universal repair for row drag. The documented ancestor workaround reads `current_target_dataset`, which belongs to the bound ancestor, not the dragged row; its sample therefore does not establish the stated workaround.

**Runtime 6: explicit pointer release.** Explicit release remains useful for ending a gesture, but “forgetting release leaves capture permanently stuck” is too broad. The adapter observes native `lostpointercapture`, removes ownership after the deferred dispatch window, and releases removed/disposed targets. All six existing adapter tests passed. This review does not add a native pointer-up browser reproduction of the historical incident.

**Runtime 7: mandatory `canvas-viewport` class.** This is an application stylesheet selector, not a Mochi-reserved name. Cowboy's `lib/styles/canvas.css:301` supplies flex sizing and `min-height: 100px` specifically to that class. The standalone layout probe uses `.viewport` successfully. Renaming markup without transferring the CSS is not evidence of a wheel API restriction.

## Claims that remain unverified

| Claim | What is missing / what would settle it |
| --- | --- |
| Compiler 10: original AppRouter failed mrbc | The failed source and stderr are not retained in feedback. A minimal state-switch component compiles, so there is no evidence for a router-class ban. Recover the original source before assigning a cause. |
| Compiler 8: large literals compile noticeably slower / extracted data is more stable | No sizes, timings, comparable builds, or failing literal are supplied. The proven IREP boundary does not establish this separate performance claim. A bounded literal-size benchmark is needed before prioritizing a compiler optimization. |
| Testing 2: Ruby static server returned an old descriptor | No response headers, cache validators, file hashes/mtimes, or browser trace. The loader uses ordinary fetch and immutable in-page resource caches; neither proves that the server caused this incident. Capture requested URL, response headers/body hash, and build hash on a reproduction. A query on the document alone does not necessarily version descriptor URLs. |
| Original raw-modal and child-event failures beyond tested shapes | The retained application contains workarounds; the exact failing revisions are absent. Current regression evidence rejects broad restrictions but cannot identify those historical causes. |

## Other feedback dispositions

- Compiler 5: Integer division is deliberate Ruby behavior; integer operands do not imply floating-point division in MRI either.
- Compiler 9: missing `mochi` on PATH is installation state. Mochi already has `task install:dev`; no product-specific absolute-path requirement follows.
- Components 3: shadow style isolation and host sizing are intended. Shared CSS imports are the existing Ruby-authored reuse mechanism.
- Runtime 3: explicit locale/timezone defaults are intentional. The documented Time subset lacks general calendar/strftime/ISO serialization; that convenience gap is separate from timestamp formatting correctness.
- Testing 5/7: geometry checks and worst-case data are useful methods, not independent framework defects. Cowboy's manual geometry notes do not replace automated interaction or lifecycle coverage.

## Priorities justified by this evidence

1. Bytecode fallback compatibility and accurate generated-to-authored diagnostics.
2. Invalid event-binding diagnostics; supported Ruby type inspection and `unshift`.
3. Decide whether Range slicing earns its core/payload cost; retain working two-argument slicing either way.
4. Document and test existing timer/storage APIs and asynchronous layout/readiness semantics.
5. Review raw-markup wrapper behavior and deliberate content projection as separate composition designs.

Do not introduce reserved event names, force one event per child, ban row components, broaden shortcut scope automatically, or add another timer API on the basis of these reports.
