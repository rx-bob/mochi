# Shared UI contract fixtures

This is one Mochi project: Ruby components in `lib/`, authored browser scenarios in `test/`, and isolated feedback probes in `probes/`. No external application checkout or network service is required. Compilation and browser servers use temporary directories; checked-in build artifacts are not modified.

E1.S1 supplies the inspector: 48 structured records, 12 rows per page, literal filtering, page clamping, stable-ID selection, and nested details. E2.S1 supplies the nested form described below. E3.S1 adds the editable graph geometry slice described below.

E1.S2 pages with ordinary `Array#slice`. The inspector target also runs
`probes/02-array-contexts/test/array_slice_test.rb`: native Ruby boundary
oracles, initialization/helper/handler/template execution, invalid arguments,
and bounded exhaustion followed by a successful smaller slice. Source and
capacity diagnostics are checked by the framework suite on each engine.

E1.S3 moves record generation and filtering into `lib/RecordData.rb` and uses
qualified constants for page size. The inspector target also runs
`probes/03-helper-contexts/test/helper_test.rb`, comparing helper results with
native Ruby across initializer, method, event, and template calls. It checks
separate module constants, nested `next`, map values, missing references, and
recovery. Unsupported rescue/ensure is a build-diagnostic probe.

E2.S1 adds `NestedFormRoot` with two keyed groups and four keyed fields.
`FieldEditor` declares String props and a typed edit event; each mounted editor
copies its current initial value into a local draft. Reordering groups/fields
or inserting/removing a neighbor preserves that draft and DOM identity.
Disabling a group or closing the form removes its editors and their route
subscriptions. Reopening creates fresh editors from current props. Help,
validation, and fallback branches exercise nested conditions in row scope.
The `01-structural-contexts` probe covers table/select/SVG/foreignObject,
shadowed loop locals, and inactive branches that must not evaluate.

E2.S2 adds mixed attribute quotes, nested Ruby interpolation, and an action
that puts quotes, angle brackets, ampersands, entities, and braces into every
field label. Ruby scenarios check static/conditional/row attributes, typed
child props, and event arguments. Framework assertions verify these values
create no extra elements. The original report 05 probes now render normally.
E2.S3 binds editor drafts before validation and inspector queries before a
pagination reset. `BindingActionsRoot` and `test/binding_actions_test.rb` cover
text, select, and checkbox controls in both attribute orders, current row
arguments after keyed moves, property resets, branch recreation, and remount.
The existing Ruby `fill` operation selects a value on a select and dispatches
its native input/change sequence; `click` toggles a checkbox. The framework
capacity probe fails the actual VM setter before its callback, then verifies
recovery on a smaller input. E2.S4 adds required/defaulted Boolean props, native required validation,
typed save/cancel events, and keyboard/focus acceptance. `BooleanPropsRoot`
checks static and conditional children; repeated editors use the same contract.
Save updates the parent's saved field value. Cancel closes the form and returns
focus to the toggle; reopening discards unsaved local drafts. Both ordinary
builds and `--typecheck` are covered. `probes/11-boolean-contracts` rejects a
string-valued Boolean event field and then delivers a valid Boolean payload.

E3.S1 adds `EditableGraphRoot`: four keyed nodes and three keyed paths using
native SVG and local Ruby hashes. Move replaces node state and updates only
the two adjacent paths. Reorder preserves node identity; remove/restore uses
stable edge IDs. Pan exercises a compound transform. Closing/reopening and
fresh component mounts verify current geometry, marker references, and branch
lifetime. Ruby scenarios cover initially open/closed branches; framework checks
observe geometry synchronously before insertion and count actual path writes.
Selection, pointer input, and bounded history arrive in later graph stories.

From the Mochi repository root:

```sh
task framework:ui            # all UI scenarios, evidence, and runner regressions
task framework:ui:inspector  # inspector Ruby scenarios and related evidence
task framework:ui:graph      # graph Ruby scenarios, insertion/identity checks, SVG/wheel evidence
task framework:ui:form       # nested form, lifecycle, contexts, and remaining form evidence
```

These tasks build the compiler and use the existing Chromium, Firefox, and WebKit matrix. The full `task framework:e2e` workflow includes the complete UI suite and runner regressions. Nothing is skipped when a probe demonstrates a current defect: it asserts that precise observation, names its owning story, and must become a normal acceptance assertion when repaired. See [the evidence inventory](../../../references/UI_FIXTURE_CONTRACTS.md) for expected behavior, current results, and limitations.

Use Mochi's Ruby workflow directly for authored scenarios:

```sh
compiler/mochi test -i e2e/fixtures/ui_contracts
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=inspector_test.rb --browsers=chromium
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=nested_form_test.rb --browsers=chromium
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=editable_graph_test.rb --browsers=chromium
```

`--test-file` selects one existing `*_test.rb` path relative to `test/`; an unknown selection fails instead of running zero tests. Omit it to run all Ruby files. Framework workflow discovers new Ruby files automatically. `editable_graph_test.rb` runs through the graph target. Each selected suite compiles the shared project and mounts only the roots its Ruby scenarios request.

Ruby test and scenario failures include the authored file and line. The runner records console errors, page exceptions, and `mochi:error` before navigation and checks every step, including initial mount and final rendering. Native driver errors are also labeled with the Ruby step. No JavaScript is needed to author scenarios.

For an intentional failure, give a nonempty message substring before the operation that should emit it:

```ruby
expect_error "expected diagnostic"
click ".invalid-action"
assert_text ".status", "ready"
```

The expectation applies to the next operation and must observe an error. Every diagnostic in that operation must match; a matching Mochi error cannot hide an unrelated console error or exception. Consumed errors do not affect subsequent valid steps. Dangling or replaced expectations fail. Asynchronous scenarios can use the existing `wait_for_settled` operation; no timers are assumed to complete merely because a synchronous assertion ran.

Ruby mount/input scenarios live in `inspector_test.rb`, `nested_form_test.rb`,
`binding_actions_test.rb`, and `editable_graph_test.rb`.
Use `wait_for_settled` after inserting lazy child components; it waits for their
mounts as well as pending host work. Use `>>>` to cross a child shadow boundary,
for example `[data-field='a'] field-editor >>> .draft`. Pointer lifecycle
coverage continues through the shared runner in
`framework_contracts/test/pointer_contracts_test.rb`. Later capability stories
extend the DSL when they need new operations.

Ruby keyboard scenarios use `focus "selector"`, `press "Tab"` or `press "Enter"`,
and `assert_focused "selector"`. Focus selectors support the same `>>>` child
shadow boundaries as other assertions. `press` drives the browser keyboard,
including native focus traversal, form validation, and submit behavior. These
operations are test-only and add no shipped adapter. Typecheck's supported
scope and default-value limits are documented in
[the Ruby surface](../../../references/RUBY_SURFACE.md#boolean-props-child-events-and-form-controls).
