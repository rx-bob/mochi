# Shared UI contract fixtures

One portable Mochi project contains three Ruby applications. Components and
helpers live in `lib/`, authored browser scenarios in `test/`, and isolated
feedback probes in `probes/`. No external application checkout, backend, or
application JavaScript is required. Builds and browser servers use temporary
directories; intentional failures in probes cannot break the shared build.

## Run and typecheck

From the Mochi repository root:

```sh
task build
task framework:ui            # all UI scenarios and contract evidence, all engines
task framework:ui:inspector
task framework:ui:graph
task framework:ui:form
task framework:e2e           # complete portable framework and asset/install suite
compiler/mochi --typecheck -i e2e/fixtures/ui_contracts -o /tmp/mochi-ui-docs
compiler/mochi test -i e2e/fixtures/ui_contracts --browsers=chromium,firefox,webkit
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=download_test.rb --browsers=chromium
```

Playwright prerequisites belong to Mochi's `e2e/` directory: run
`cd e2e && npm ci && npx playwright install chromium firefox webkit` from the
checkout once. `--test-file` selects an existing `*_test.rb` path relative to
`test/`; an unknown selection fails. Omit it to run all Ruby scenarios. The
framework discovers new Ruby test files automatically and includes the whole
fixture suite in `framework:e2e`. `task e2e` is the separate application
integration, not the portable fixture command.

## Paginated inspector

[InspectorRoot](lib/InspectorRoot.rb) retains 480 structured records and renders
12 per page. [RecordData](lib/RecordData.rb) supplies stable string IDs,
severities, Unicode messages, nested source/sequence/millisecond timestamps,
and nested attribute arrays. Filtering is a literal substring operation.
Selection survives filtering and clears on selected-record removal or retention
eviction. Append retains the newest 480 records and clamps page bounds.

Computed ordering, filtering, paging, selection and details share their results.
Paging does not refilter; toggling details does not rescan records. Initialization
publishes each completed record before building the next to bound scratch work.
The following excerpt is compiled as part of the complete InspectorRoot class:

```ruby
computed :filtered_records, depends_on: [:ordered_records, :@query]
computed :visible_records, depends_on: [:filtered_records, :@page]

def filtered_records
  RecordData.filter(ordered_records, @query)
end

def visible_records
  filtered_records.slice(@page * RecordData::PAGE_SIZE, RecordData::PAGE_SIZE)
end
```

`ordered_records` is another declared computed method in that class. Collection
edits replace the owning root; assigning the same handle or mutating a hidden
nested hash does not promise invalidation. Cached collections are read-only
inputs. See [computed and array contracts](../../../references/RUBY_SURFACE.md).

Timestamps sort by original integer milliseconds; `RecordData.instant` converts
explicitly to `Time.at(milliseconds / 1000.0)`. UTC/Tokyo display changes preserve
ordering and selection. JSONL/CSV buttons export **all currently filtered rows
in current order**, including off-page rows. JSONL generates one record per
line; CSV quotes fields and doubles quotes. Empty selections produce empty
JSONL/header-only CSV. [Download rules](../../../references/DOWNLOAD_CONTRACT.md)
define byte/MIME/filename bounds and disposal-safe URL leases.

Tests: [inspector_test.rb](test/inspector_test.rb) visits all forty pages,
filter/empty/recovery/append/eviction/selection/time cases;
[download_test.rb](test/download_test.rb) compares actual filenames and bytes
against MRI JSON/CSV oracles, including Unicode, commas, quotes and newlines.

## Nested form

[NestedFormRoot](lib/NestedFormRoot.rb) has two keyed groups and four keyed
fields. Each [FieldEditor](lib/FieldEditor.rb) copies current props into a local
draft on mount and declares String/Boolean props plus typed edit/save/cancel
events. Reorder or neighbor insertion/removal preserves draft and DOM identity.
Disabling a group or closing the form disposes its editors and subscriptions;
reopening creates fresh drafts from current props. Saving updates parent values;
cancel discards unsaved drafts and restores opener focus.

The editor input uses `bind:value="{@draft}" oninput="{edit}"`. Its handler
sees the updated value regardless of HTML attribute order. Required validation,
Boolean `required`/`disabled`, quoted labels and nested branch scope are tested.
Open dialogs own Escape through nested inputs and suppress graph shortcuts;
`active_ref: "dialog"` also covers parent-driven open/close changes.

Tests: [nested_form_test.rb](test/nested_form_test.rb),
[binding_actions_test.rb](test/binding_actions_test.rb), and
[Boolean mismatch/recovery](probes/11-boolean-contracts/test/boolean_test.rb).
Both shared form and Boolean probes build with `--typecheck`. Browser checks
verify keyed identity and that adversarial labels create no extra elements.

## Editable graph

[EditableGraphRoot](lib/EditableGraphRoot.rb) starts with four keyed nodes and
three native SVG paths. Node/edge roots feed one computed geometry projection.
Moving one node updates only adjacent paths; reorder preserves node identity.
Synchronous browser audits check valid geometry before insertion, namespace/case,
markers, exact path writes, and branch recreation. It does not compose custom
component children inside SVG.

Add/remove/drag edits retain at most **40 undo/redo snapshots combined**. Current
model and one active-drag rollback snapshot are separate. Snapshots copy
node/edge arrays and hashes, selection, ID counter and ordering. A new edit
clears redo; removing a node removes incident edges. Pan and viewport open state
stay outside model history. No-op drags add no entry. Cancel, capture loss or
branch closure restores the starting model without committing history.

Pointer capture belongs to the keyed SVG group, including presses on its circle
or label. Fit uses the measured viewport with 24-pixel padding; drag inverts its
scale. Zero/hidden, too-small and empty graph states are explicit. Wheel zoom
keeps the pointer anchor and clamps to 0.25–4; line units use 16 pixels and page
units use measured height. Scrolling is prevented only over the graph region.
Ctrl/Meta+Z and Shift+Z act while graph focus is active; its note input retains
native text editing. A form's active application scope takes precedence.

Tests: [editable_graph_test.rb](test/editable_graph_test.rb) performs 45 edits,
all 40 undo/redo steps, branch-after-undo, restoration and drag cancellation.
[Browser contracts](../../tests/gvm_ui_contracts.spec.ts) inspect capture,
geometry, layout/zoom/keyboard behavior and optional adapter requests.

## Ownership, failures and Ruby test operations

| Facility | Lifetime and evidence |
| --- | --- |
| [Computed values](../../../references/RUBY_SURFACE.md#explicit-computed-values) | Per-instance cache, invalidated by declared roots; GC/unmount release results. Helpers must stay pure. [Projection tests](../../tests/gvm_computed.spec.ts). |
| [Pointer](../../../references/POINTER_CONTRACT.md), [layout](../../../references/LAYOUT_CONTRACT.md), [wheel](../../../references/WHEEL_CONTRACT.md) | Mount-owned capture/observers/queued work; cancellation, branch reconciliation and disposal prevent stale delivery. Wheel/layout coalesce frame work. |
| [Shortcuts](../../../references/SHORTCUT_CONTRACT.md) | Owned registrations with focus/application scope and static active refs; disposal removes registrations. |
| [Files](../../../references/DRAG_FILE_CONTRACT.md) | Opaque mount-owned handles/readers; cancellation/disposal closes readers and suppresses callbacks. Whole reads default to 48,000 bytes, chunks to 8,192. |
| [Downloads](../../../references/DOWNLOAD_CONTRACT.md) | Ready before controls render; start during user activation. Failure releases URLs immediately; accepted URLs survive disposal until bounded 30-second expiry. |

[Capacity boundaries](../../tests/gvm_capacity_boundaries.spec.ts) force scratch,
computed-cache and persistent failures. Failed entries preserve rendered values
and discard queued host work; earlier Ruby mutations are not rolled back.
[Lifecycle coverage](../../tests/gvm_ui_capacity_lifecycle.spec.ts) runs 100
interactions plus 100 mount/disposal cycles under a constrained profile, checking
released state, routes, editor drafts and graph history. Defaults are not raised.

Ruby selectors begin inside the mounted root. Use `>>>` to cross a child shadow
boundary, such as `[data-field='a'] field-editor >>> .draft`. `fill` handles text
and selects; `click` handles controls/SVG. `focus`, `press` and `assert_focused`
drive native keyboard behavior. `wait_for_settled` waits for lazy child mounts
and pending host work. Download scenarios use trusted clicks and real artifacts:

```ruby
# From test/download_test.rb, where jsonl and records are MRI-built expectations.
download ".export-jsonl"
assert_download filename: "records.jsonl", bytes: jsonl.call(records)
```

Negative scenarios place `expect_error "diagnostic substring"` immediately before
the failing action. Every diagnostic in that operation must match; missing,
unrelated or dangling expectations fail. Console/page/runtime capture starts
before navigation. Errors include the authored Ruby test file and line. See
[the current inventory](../../../references/UI_FIXTURE_CONTRACTS.md) for exact
negative probes; none are skipped as a substitute for evidence.

## Supported scope and deferrals

These are bounded examples, not reusable graph/form libraries or complete
import/export products. Full MRI/Regexp/Date/Math, Range slicing, nonlocal block
return/break, rescue/ensure, redo, slots, SVG custom-element composition,
automatic deep mutation observation, arbitrary DOM/window access and dynamic
row refs remain unsupported. Streaming file reads already exist; streaming
output, save pickers and filesystem writes are deferred.

Public assets keep their `public/` output path. Shared CSS belongs under `lib/`
(for example `lib/styles/`), with component-relative imports; project-root
`styles/` is not staged. Icons are selected project assets under `icons/`, not
an implicit Lucide catalog. [Asset probes](probes/12-assets-css) and the retained
[root-style diagnostic](probes/12-root-css) define those boundaries.
