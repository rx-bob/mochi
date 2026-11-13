# Supported Ruby surface

Mochi implements a practical Ruby interface for browser applications. This
document records supported forms and explicit VM limits. It does not promise
full MRI, Enumerable, or arbitrary-precision compatibility.

## Explicit computed values

Declare a pure, zero-argument component method and its dependencies:

```ruby
computed :visible_rows, depends_on: [:@records, :@query, :@page, :@page_size]
computed :selected_label, depends_on: [:selected_record]
computed :selected_record, depends_on: [:@records, :@selected_id]
```

`:@name` names an instance-variable root (including a declared prop); `:name`
names another computed method declared in the same class. Declaration order
does not matter. Root names must appear in the component source or its prop
declarations. Methods must exist in that class and accept no arguments;
`initialize` cannot be computed. Cycles, unknown dependencies, undeclared
reads/calls visible in component methods, and detectable state writes or host
effects fail with Ruby source locations. Dependencies through arbitrary helper
code are not inferred: authors must declare every input and keep helpers pure.

Evaluation is lazy. Each instance retains one result until a declared root
changes; all callers and bindings share that result. Unrelated state changes
do not recompute it. Computed dependencies expand to their root dependencies;
ordinary Ruby calls determine lazy evaluation order. Merely listing a computed
dependency does not eagerly call it. An inherited computed method retains its
contract; an ordinary subclass override replaces that declaration.

**Replace the owning root to publish nested changes.** For example:

```ruby
@records = @records.map do |record|
  record["id"] == edited_id ? record.merge({"label" => new_label}) : record
end
```

In-place Ruby mutation remains supported outside computed evaluation, but
hidden nested changes do not promise computed invalidation. Reassigning the
same collection handle does not count as replacement. Distinct arrays/hashes
do; scalars and strings use the existing state equality rules. Treat cached
collections as read-only inputs and construct replacements for edits.

Getters may construct and mutate fresh local arrays/hashes. They must not write
component state, mutate retained collections (including aliases), or call host
operations/native adapters. Runtime guards cover indirect helper effects and
reentrant evaluation. Errors retain source context, invalidate the failed
evaluation, and permit retry after a valid input change. Cached graphs survive
GC; invalidation and unmount release their retained references. See the
[computed probe](../e2e/fixtures/ui_contracts/probes/12-computed/lib/ProbeRoot.rb)
and [capacity contract](CAPACITY_CONTRACT.md).

## Template loops and conditional branches

`{each ... as item, index, key: ...}` and `{if ...}` / `{elsif ...}` /
`{else}` can nest in either order. Branches retain the enclosing loop locals
for text, attributes, child props, event arguments, and further conditions.
An inner loop introduces its own item/index locals; reusing a name shadows
the outer value inside that loop without overwriting it afterward. The
implicit `index` always refers to the innermost loop. Only selected row
branches evaluate their expressions and nested loops.

The [nested form](../e2e/fixtures/ui_contracts/lib/NestedFormRoot.rb) provides
an executable example. Stable keys preserve an editor's DOM identity and
local draft through reorders and neighboring insertions/removals. Conditional
removal unmounts child components and releases their owned resources;
recreation starts fresh child state from current props. Event arguments use
current row values and indices after a move.

Fragments retain table, select, HTML, and SVG insertion context, including
HTML children of SVG `foreignObject`. Invalid table nesting and malformed
expressions report authored source locations. Dynamic SVG attributes remain
inert during template parsing. Keyed rows and conditional branches apply their
available geometry before live insertion; ordinary root attributes remain
absent until the initial patch. Compound attributes resolve all slots before
writing, and SVG names such as `viewBox` and `refX` retain their canonical case.
Unchanged path values cause no DOM attribute write. The
[editable graph](../e2e/fixtures/ui_contracts/lib/EditableGraphRoot.rb) demonstrates
moves, keyed reorders, removal/reinsertion, marker references, and branch
recreation without raw markup. This does not add SVG custom-element
composition, slots, or automatic deep mutation observation. Replace root
state to publish nested model changes.

The graph also demonstrates fixture-owned undo/redo using ordinary `map`,
fresh hashes, and `slice`: only the current graph is copied into a new snapshot,
and the two history arrays retain at most 40 snapshots combined. Existing
snapshots are reused immutably; restoring one creates a fresh working model.
Node deletion removes incident edges, and future IDs replay deterministically.
Pointer cancellation restores the pre-gesture model without committing history.
This is application Ruby code, not a framework state-store or history API.

## Native event identity

Native handlers receive plain hashes. `event["dataset"]` retains target data;
`event["target_dataset"]` names the same snapshot explicitly.
`event["current_target_dataset"]` identifies the element carrying the bound
handler, even when a nested label, SVG shape, or table cell receives the click.
All dataset values are strings; keys use DOM dataset casing, with internal
`mochi*` keys filtered. Applications need no ancestor scan or artificial DOM ID.

The target follows browser shadow retargeting. A handler outside a nested
shadow root sees the child host's dataset, while its own bound element supplies
current-target data. Path entries retain only their existing labels. Typed child
events deliver their declared payload without added native event metadata.
Snapshots are taken before queued Ruby delivery; removing the bound element
before delivery drops that event. Dataset values share the existing bounded
[argument envelope and recovery contract](CAPACITY_CONTRACT.md).

## Boolean props, child events, and form controls

A component can declare `prop :required, Boolean, required: true`,
`prop :disabled, Boolean, default: false`, and
`event :save, value: String, valid: Boolean`. These declarations work in
ordinary builds and `--typecheck`, including `# typed: true` sources.
`Boolean` is declaration syntax, not a general Ruby constant. Typecheck
preparation adapts only these metadata positions to Sorbet's Boolean type and
supplies declaration/emitter method stubs only inside the owning component.
Other unknown constants and ordinary signed-method type errors still fail.
Diagnostics retain authored lines and columns.

The compiler rejects incompatible literal defaults such as
`default: "false"` for a Boolean prop. Existing defaults remain a narrower
contract: `nil` is permitted for every prop type, and constant defaults are
evaluated as Ruby without checking the resulting value against the prop type.
Sorbet still checks whether those constants resolve. Declarations do not infer
Sorbet ivar types or statically check arbitrary emitted hashes. At runtime,
supplied props and declared event payloads are checked; a Boolean payload field
requires actual `true` or `false`, and a mismatch stops parent delivery.

Declared child props retain values even when their names are also native HTML
Boolean attributes. A child's `required="{false}"` supplies false; an ordinary
input's `required="{false}"` removes its required attribute. Static, conditional,
and repeated children follow the same distinction without fetching their
component descriptors early.

The nested-form fixture uses associated labels, native text inputs, required
validation, and form submission. Save emits the current draft and Boolean
validity to the parent, which updates that field's saved value. Cancel closes
the form, discards local drafts, and returns focus to the static toggle button
through `Mochi.focus`. Closing the form also returns focus there. Reopening
creates editors from the latest saved values. Keyed reorders preserve the
focused input; Save and Cancel explicitly use `tabindex="0"` so WebKit's
platform tab policy also includes those buttons. No custom keyboard handler
replaces native Tab or Enter behavior.

## Bound controls and explicit handlers

`bind:value="{@draft}"` writes `@draft` on text input's `input` event;
`bind:checked="{@enabled}"` writes the checked Boolean on `change`.
A select's `bind:value` synchronizes on `change`. Bare `bind:value="@draft"`
is also accepted. Binding targets must be a single component instance variable.

When the same control also declares `oninput` or `onchange` for that event,
Mochi writes the bound variable first, evaluates explicit Ruby arguments from
that updated state, calls the handler once, then flushes through the existing
VM entry. Attribute order does not affect this sequence. For example:

```ruby
def validate
  @message = @draft.empty? ? "Required" : "Valid: #{@draft}"
end

def html
  %q{<input oninput="{validate}" bind:value="{@draft}">}
end
```

A select's native `input` event does not invoke its explicit `onchange`
handler; its following `change` event synchronizes and invokes once. Existing
`.self`, `.prevent`, and `.stop` modifiers run before the composed action.
Bare handlers keep the existing implicit payload rule: one leading required
positional parameter receives the event. Explicit `$event` remains supported.

The same contract applies in conditional branches and keyed rows. Row arguments
use current item/index scope after moves. Programmatic state changes update
control properties. A failed setter stops the handler and skips the successful
entry flush; failed host effects are discarded, and later valid events can
recover. This does not add transaction rollback for earlier successful writes
within a failing handler.

## Ruby expressions inside attributes

HTML attribute quotes do not end an embedded Ruby expression. Both forms
below evaluate the same hash lookup, including in rows, conditional branches,
typed child props, and event arguments:

```ruby
def html
  %q~<p title="{@field["label"]}" data-alt='{@field['label']}'>
    {@field["label"]}
  </p>~
end
```

Ruby strings can contain escaped quotes, braces, nested hashes, and string
interpolation inside an explicit `{...}` placeholder. Percent literals use
their Ruby delimiters and escape rules. Choose an outer Ruby template string
delimiter that does not conflict with its contents, as in `%q~...~` above.
Bare `#{...}` outside a placeholder remains unsupported template syntax.
Event arguments with escapes or interpolation execute through Ruby; they do
not use a separate JavaScript string evaluator.

Dynamic values stay data in text and attributes, even when they contain
quotes, `<img>` markup, `&quot;`, or `{end}`. Only a whole text expression
wrapped with `Mochi.raw(...)` opts into trusted markup. Literal HTML entities
outside Ruby expressions decode once, including conditional attribute text;
entities inside Ruby strings retain their exact Ruby value.

`{{literal}}` escapes braces in text and quoted attributes. Attribute hashes
retain `class={{ "active" => @active }}` and the quoted equivalent. In quoted
attributes a valid hash, an empty hash, or explicit pair/splat syntax selects
the hash form; malformed explicit pairs still fail validation. Other doubled
braces remain literal text. Unquoted `{{...}}` always requires a valid hash.
Malformed/unclosed placeholders report the authored Ruby file and line.

## Helper constants, receivers, and block control flow

Top-level helper modules can define constants and singleton methods using
ordinary Ruby. `RecordData::BASE` reads that module's constant, and
`RecordData.build` keeps `RecordData` as its receiver. Two helper modules may
each define `BASE` without sharing its value or creating a duplicate-package
error. Bare constant reads in a helper method use its defining module; blocks
retain that lexical owner and their enclosing locals.

These forms work in component initialization, ordinary methods, handlers, and
template expressions. The inspector's [RecordData helper](../e2e/fixtures/ui_contracts/lib/RecordData.rb)
owns record generation, constants, and literal filtering. Missing qualified
constants identify the authored name, such as `RecordData::MISSING`; missing
singleton calls identify the actual receiver and method. Runtime source
locations retain the existing descriptor granularity: the invoked component
method declaration or generated template binding, rather than an exact
instruction line inside a helper.

`next` and postfix `next if` skip only the current `each`/`map` iteration.
`next value` supplies that iteration's `map` result; bare `next` supplies
`nil`. Nested loops preserve outer locals, and the enclosing method continues
after iteration. These forms use normal local block-return bytecodes; no
extra control-flow runtime is needed.

The compiler verifies actual mruby 4.0 instruction numbers and every nested
IREP before emitting a bundle. Unsupported block `break`, nonlocal block
`return`, rescue/ensure, Range bytecodes, and `redo` fail at build time with
the construct name and authored source location. Ordinary method `return`
and supported while-loop `break`/`next` remain valid. The bare keyword `redo`
is not a valid handler method name. On opcode rejection, a temporary debug
compile supplies mrbc's line table; successful bundles contain no added debug
section.

This contract does not add arbitrary nested class/module registration,
constant inheritance/`const_missing`, or full Ruby exception and nonlocal
unwinding semantics. Essential scoped constant dispatch remains in the VM;
helpers continue to load as dependency-selected Ruby bytecode.

## Numeric rounding

`Integer` and binary64 `Float` support these ordinary methods:

| Method | Supported call | Return type |
| --- | --- | --- |
| `round` | `number.round` | Integer |
| `round` | `number.round(ndigits)` | Integer for Integer receivers or `ndigits <= 0`; Float for Float receivers and `ndigits > 0` |
| `round` | `number.round(ndigits, half: mode)` or `number.round(half: mode)` | Same as `round` above |
| `floor`, `ceil` | `number.floor`, `number.ceil` | Integer |
| `floor`, `ceil` | `number.floor(ndigits)`, `number.ceil(ndigits)` | Integer for `ndigits <= 0`; Float for positive precision on Float receivers; Integer receivers remain Integer |

`ndigits` must be an Integer in the inclusive range `-18..18`. Integer
receivers with nonnegative precision return unchanged. Negative precision
rounds to a power-of-ten multiple. Negative values use mathematical floor and
ceiling, and `round` defaults to nearest with exact halves away from zero.

The supported `half:` values are `:up` (nearest, ties away from zero), `:down`
(nearest, ties toward zero), and `:even` (nearest, ties to an even result).
Unknown options or modes produce an `invalid argument` error. Wrong arity,
nonnumeric receivers, and non-Integer precision produce source-located VM
errors. Precision outside the bound produces `invalid argument`.

Float calculations remain binary64 operations in the VM. Positive precision
preserves signed zero; positive-precision NaN and Infinity are returned
unchanged. At zero or negative precision, NaN or Infinity produces a
`non-finite float` error. A finite result outside the signed 64-bit Integer
range produces `integer overflow`. Integer results remain within the VM's
checked signed 64-bit range. These methods do
not provide decimal arithmetic or exact currency calculations; use
[`MochiMoney`](../README.md#money-helpers) for exact minor-unit accumulation.

Examples:

```ruby
(-1.5).round                 # -2
2.5.round(half: :even)        # 2
(-1.21).floor(1)              # -1.3
(-1.21).ceil(1)               # -1.2
12.floor(-1)                  # 10
```

Rounding is implemented as small VM numeric operations. It does not load the
number-formatting adapter or add a Ruby package dependency. The Float results
are binary64 and should not be used as exact-money values.

## Array indexing and slicing

`array[index]` and `array.slice(index)` return one element, or `nil` outside
the array. `array[start, length]`, `array.[](start, length)`, and
`array.slice(start, length)` return a fresh shallow array. Negative indices
count back from the end. Slicing never changes the receiver; nested objects
retain their identity, so mutating a shared nested object affects both arrays.

For `a = [1, 2, 3, 4]`, both two-argument forms follow this Ruby oracle:

| Arguments | Result |
| --- | --- |
| `1, 2` | `[2, 3]` |
| `-2, 9` | `[3, 4]` |
| `-4, 2` | `[1, 2]` |
| `-5, 2` | `nil` |
| `0, -1` | `nil` |
| `1, 0` | `[]` |
| `4, 2` or `4, 0` | `[]` |
| `5, 0` | `nil` |
| `0, 9223372036854775807` | `[1, 2, 3, 4]` |
| `-9223372036854775808, 2` | `nil` |

An empty receiver returns `[]` at start zero and `nil` beyond it. Scalar
access at the end returns `nil`, unlike a two-argument slice at the end.
Both methods require one or two Integer arguments in the VM's signed 64-bit
range. Unsupported argument types produce `type mismatch`; wrong arity
produces `wrong number of arguments`, with the authored method/source location.
Float or `to_int` coercion, Range arguments, and `slice!` are outside this
contract.

These calls work on scratch and persistent arrays in initialization, helpers,
event handlers, and template getters. A successful slice uses one scratch
object and one slot per returned element, including a fresh object for `[]`.
The linked storage is traversed once to the start and then through the returned
elements: time is O(start + returned count), allocation O(returned count).
Resource bounds are checked before allocation. Exhaustion identifies scratch
objects or slots and the requested/used/capacity counts; it does not return a
truncated successful slice. A later valid VM entry can slice again.

Slicing is an essential VM collection operation with no optional package or
host adapter. E1.S2 adds 2,007 raw / 887 gzip bytes to the core WASM; see
[payload budgets](PAYLOAD_BUDGETS.md). Array `to_s`/direct array text rendering
remains a separate unsupported surface; use explicit element formatting such
as `join` for the supported values in these fixtures.

## Array aggregation

`Array#sum`, `Array#min`, and `Array#max` are loaded as optional Ruby bytecode
when a supported receiver call appears in a component or helper source. The
compiler tracks method-call syntax and helper dependencies; applications that
do not use these methods do not download the collection package.

- `sum` accepts an optional initial value and a block. A block transforms each
  element before addition. Numeric accumulation uses the VM's checked Integer
  and binary64 Float arithmetic; mixed numeric values promote to Float, and
  integer overflow is an error.
- `min` and `max` return `nil` for an empty array. Without a block, this version
  supports Integer, Float, and String ordering. With a block, the comparator
  receives the candidate and current value and must return a numeric ordering;
  `min` replaces the current value when the result is negative, while `max`
  replaces it when the result is positive.
- The size forms (`min(n)` and `max(n)`), enumerators, and nonnumeric `sum`
  operands are unsupported. Incomparable values and invalid comparator results
  produce source-located VM errors.

All forms use one pass and constant extra storage. The optional package adds no
host adapter and does not enter an app's initial package set unless its Ruby
call graph reaches one of these methods.

## Array sorting

`sort_by` accepts a key block and evaluates it once for each element. `sort`
accepts a comparator block with the usual two arguments; return a negative
number when the left value belongs first, zero when they compare equal, and a
positive number when the right value belongs first. For descending order,
reverse the comparison with `right <=> left`:

```ruby
rows.sort_by { |row| row[:rank] }
scores.sort { |left, right| right <=> left }
```

Both block forms return a new array and leave the receiver unchanged. Sort keys
support Integer, Float, and String comparisons; unordered or incomparable keys
and nonnumeric comparator results raise a source-located VM error. Equal-key
ordering is unspecified. Sorting uses a bottom-up merge sort, so sorted and
reverse-sorted inputs avoid quadratic comparison counts. The temporary output
and key arrays share the VM's bounded scratch-slot pool; an exhausted pool
raises `scratch full` without returning a partial result. A sort operation is
limited to at most half the configured scratch slots (currently 2048 elements)
before accounting for slots already used by the current VM entry.
