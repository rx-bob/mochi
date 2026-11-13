# Shared UI contract fixtures

This is one Mochi project: Ruby components in `lib/`, authored browser scenarios in `test/`, and isolated feedback probes in `probes/`. No external application checkout or network service is required. Compilation and browser servers use temporary directories; checked-in build artifacts are not modified.

E1.S1 supplies the inspector: 48 structured records, 12 rows per page, literal filtering, page clamping, stable-ID selection, and nested details. E2.S1 supplies the nested form described below. The editable graph remains E3.S1; its workflow target currently runs the relevant feedback evidence.

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

Inputs use explicit handlers for this story. Binding/handler composition,
mixed attribute quotes, and Boolean typechecking remain E2.S2–E2.S4.

From the Mochi repository root:

```sh
task framework:ui            # all UI scenarios, evidence, and runner regressions
task framework:ui:inspector  # inspector Ruby scenarios and related evidence
task framework:ui:graph      # SVG/wheel evidence; graph Ruby scenarios once added
task framework:ui:form       # nested form, lifecycle, contexts, and remaining form evidence
```

These tasks build the compiler and use the existing Chromium, Firefox, and WebKit matrix. The full `task framework:e2e` workflow includes the complete UI suite and runner regressions. Nothing is skipped when a probe demonstrates a current defect: it asserts that precise observation, names its owning story, and must become a normal acceptance assertion when repaired. See [the evidence inventory](../../../references/UI_FIXTURE_CONTRACTS.md) for expected behavior, current results, and limitations.

Use Mochi's Ruby workflow directly for authored scenarios:

```sh
compiler/mochi test -i e2e/fixtures/ui_contracts
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=inspector_test.rb --browsers=chromium
compiler/mochi test -i e2e/fixtures/ui_contracts --test-file=nested_form_test.rb --browsers=chromium
```

`--test-file` selects one existing `*_test.rb` path relative to `test/`; an unknown selection fails instead of running zero tests. Omit it to run all Ruby files. Framework workflow discovers new Ruby files automatically. `editable_graph_test.rb` will join the graph target in E3.S1. Each selected suite compiles the shared project and mounts only the roots its Ruby scenarios request.

Ruby test and scenario failures include the authored file and line. The runner records console errors, page exceptions, and `mochi:error` before navigation and checks every step, including initial mount and final rendering. Native driver errors are also labeled with the Ruby step. No JavaScript is needed to author scenarios.

For an intentional failure, give a nonempty message substring before the operation that should emit it:

```ruby
expect_error "expected diagnostic"
click ".invalid-action"
assert_text ".status", "ready"
```

The expectation applies to the next operation and must observe an error. Every diagnostic in that operation must match; a matching Mochi error cannot hide an unrelated console error or exception. Consumed errors do not affect subsequent valid steps. Dangling or replaced expectations fail. Asynchronous scenarios can use the existing `wait_for_settled` operation; no timers are assumed to complete merely because a synchronous assertion ran.

Ruby mount/input scenarios live in `inspector_test.rb` and `nested_form_test.rb`.
Use `wait_for_settled` after inserting lazy child components; it waits for their
mounts as well as pending host work. Use `>>>` to cross a child shadow boundary,
for example `[data-field='a'] field-editor >>> .draft`. Pointer lifecycle
coverage continues through the shared runner in
`framework_contracts/test/pointer_contracts_test.rb`. Later capability stories
extend the DSL when they need new operations.
