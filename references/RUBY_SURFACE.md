# Supported Ruby surface

Mochi implements a practical Ruby interface for browser applications. This
document records supported forms and explicit VM limits. It does not promise
full MRI, Enumerable, or arbitrary-precision compatibility.

The [three-fixture guide](../e2e/fixtures/ui_contracts/README.md) links complete
buildable/typechecked examples and Ruby-authored tests. Labeled fixture excerpts
below belong to their linked complete classes/modules, not standalone components. The
[current feedback inventory](UI_FIXTURE_CONTRACTS.md) distinguishes supported,
intentional and deferred outcomes from historical observations.
For workflows, start with the [Ruby task guide](RUBY_TASK_GUIDE.md).

## Optional downloads

`MochiDownload.save(filename, content_type, content)` hands a bounded String or
Array of byte String parts to the browser during a live user action. The optional
package and adapter load before component controls render. Mochi owns the Blob,
temporary URL, activation checks, capacity errors, and cleanup. See the
[download contract](DOWNLOAD_CONTRACT.md) for bounds, filename/MIME rules,
disposal behavior, inspector JSONL/CSV semantics, and Ruby download assertions.

## Optional JSON

```ruby
require 'json'

record = JSON.parse('{"id":9007199254740993,"values":[true,null,"é"]}')
text = JSON.generate(record)
```

Use a standalone, top-level literal `require 'json'`. The compiler resolves
real local files first, then the optional built-in JSON package. Dependency
loading happens before the consuming package executes; the compiler removes
the static import while preserving source positions. Runtime/dynamic require,
loading return values, parser options, custom object hooks, and the broader
MRI JSON API are not supported. Helpers can import JSON and pass that dependency
to their consumers. Direct `JSON` references also select the package.

Supported values are String-keyed Hashes, Arrays, UTF-8 Strings, signed 64-bit
Integers, finite binary64 Floats, true, false, and nil. Parsed keys are Strings.
Duplicate object keys use the last value and retain the first insertion position.
Generation preserves Hash insertion order. Symbols (including keys), component
instances, and other unsupported objects fail rather than being coerced.
Objects named `__mochi_number` or `__mochi_bytes` remain ordinary JSON objects;
the bridge's private transport markers are not interpreted by this API.

Both operations accept at most **48,000 bytes** per document, including input
whitespace or generated punctuation/escapes. At most **16 nested containers**
are allowed, counting an empty Array/Hash; scalar roots consume no nesting.
Existing scratch/state object, slot, and byte capacities still apply and can
reject a smaller document containing many nodes. No capacity defaults change.
These are whole-document operations, not a streaming parser or a promise that
an arbitrarily large file fits in a Ruby String. Use `MochiFiles.read_text` for
bounded whole-file UTF-8 input; its default limit is also 48,000 bytes.

Input must contain one complete JSON value. Whitespace is space, tab, CR, or LF.
Trailing input, invalid escapes, lone UTF-16 surrogates, control characters in
strings, malformed UTF-8 (including overlong encodings), and a UTF-8 BOM fail.
Escaped surrogate pairs decode to UTF-8. Generation emits Unicode directly,
escapes quotes, backslashes and controls, and does not escape `/`. Invalid
UTF-8 Ruby Strings fail. Cycles fail; repeated references without a cycle are
allowed and generate independent JSON subtrees.

Integer tokens must fit **−9,223,372,036,854,775,808 through
9,223,372,036,854,775,807**. No JavaScript-number conversion occurs, including
above 2^53. Decimal/exponent tokens become binary64 Floats: rounding is to the
supported binary64 representation, subnormals are supported, underflow may
become zero, and overflow/non-finite values fail. Generation uses round-trip
float formatting, preserving negative zero; integers remain decimal integers.

Errors identify malformed JSON/UTF-8, byte/nesting limits, cycles, unsupported
types, non-finite floats, or arena capacity, with Ruby source context. Failed
operations do not return successful partial values; the next valid event can
succeed. These are VM errors, not a claim of MRI `JSON::ParserError`/rescue
compatibility. Parsing and generation are pure and may run in computed getters.

The optional package contains only Ruby entry methods, with no JSON host adapter
or JavaScript API. Strict decoding and generation reuse VM machinery and add an
explicit shared WASM cost; see [payload accounting](PAYLOAD_BUDGETS.md).
The [inspector](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb) parses a small
sample and round-trips only its selected record. The
[file contract](../e2e/fixtures/framework_contracts/lib/JsonFileContract.rb)
exercises existing bounded file reads without an inspector import workflow.

## Storage and subscriptions

`Mochi.storage_get`, `storage_set`, and `storage_remove` persist raw Strings.
Use the optional `MochiStore` battery for one string-valued preference, then
use the JSON package when that preference has a small structured shape:

```ruby
require 'json'

def initialize
  @store = MochiStore.build("theme_preferences", '{"theme":"light"}')
  stored = MochiStore.value(@store) # available before initialize finishes
  # validate stored, then install the Ruby default or decoded preference
  Mochi.storage_subscribe("theme_preferences", "on_preferences")
end
```

Validate stored text and its decoded Hash keys, types, and allowed values before
using it. This VM does not provide MRI exception rescue for malformed JSON; use
a bounded, explicit format check before `JSON.parse`, and apply a Ruby default
when text or shape is unexpected. Write corrected text back when desired. See
the [runnable preference fixture](../e2e/fixtures/feedback_review/lib/StorageRoot.rb).

`MochiStore.write` returns `false` for a value already present in the VM and
`true` when it queues a changed storage command. That is not a persistence
receipt: browser storage runs after the Ruby entry. Apply subscription payloads
with `MochiStore.accept`; successful payloads confirm the new value, while a
failed payload restores the previous persisted value and exposes `quota` or
`unavailable` through `MochiStore.error`. The loader also reports a `storage`
phase `mochi:error`. Equal writes produce no event. Same-tab writes and removals
notify directly; other tabs notify through `storage` events; removal supplies
`nil` and the Ruby default can take effect. Unmount disposes subscriptions, but
a screen hidden while still mounted remains subscribed.
`MochiStore.clear` queues a removal and returns the local default; use its
subscription payload to confirm removal or observe failure.

Each value must fit the active profile's `host_emit_envelope_bytes` command
limit after escaping and envelope overhead; a JSON document limit does not make
that whole document fit in one storage command. See [capacity limits](../docs/fixed-capacities.md)
and [capacity failure behavior](CAPACITY_CONTRACT.md). Keep storage for small
preferences and drafts, not documents. MochiStore is emitted only when used;
see [payload accounting](PAYLOAD_BUDGETS.md).

## Optional wall clock and Unix timestamps

```ruby
require 'time'                         # optional; direct Time references also resolve it
instant = Time.at(-1.25)                # Unix seconds
instant.to_i                           # -2 (floor, including before the epoch)
instant.to_f                           # -1.25
instant.utc == instant                 # true
current = Time.now.utc                 # wall time, not elapsed duration
MochiFormat.timestamp(current.to_f, "en-GB", "Asia/Tokyo",
  {"hour" => "2-digit", "minute" => "2-digit", "hour_cycle" => "h23"})
```

This is a small UTC-instant subset: `Time.now`, `Time.at(seconds)`, `to_i`,
`to_f`, and `utc`. `Time.at` accepts exactly one Integer or finite Float, in
**−8,640,000,000,000 through +8,640,000,000,000 Unix seconds**, inclusive.
Integer inputs stay exact; Float inputs retain their binary64 value without
millisecond quantization. `to_f` returns seconds, and `to_i` floors seconds.
`Time.at(value.to_f).to_f` preserves the returned numeric instant. Float
resolution depends on magnitude; the far ends of this range cannot represent
every millisecond. This is not arbitrary-precision rational/nanosecond Time.

The host clock returns checked integer **Unix milliseconds**. `Time.now`
divides by 1,000.0 exactly once to obtain binary64 seconds. Its source has
millisecond resolution and follows wall-clock changes; it is not monotonic.
Internal elapsed-duration measurements continue using their existing monotonic
clock. It adds no scheduling API, calendar arithmetic, timezone database, or
Date compatibility; mount-owned scheduling is provided separately by
[`Mochi.after` and `Mochi.every`](TIMER_CONTRACT.md).

These Time values have no mutable local timezone mode. `utc` returns the same
object and preserves its instant. Calendar constructors (`Time.new`,
`Time.utc(year, ...)`), subsecond/unit overloads of `Time.at`, parsing,
`strftime`, local-zone conversion, and other Date/Time methods are unsupported.
Wrong types, argument counts, non-finite values, range violations, and missing
methods report Ruby source context; a valid subsequent event can succeed.
`Time.at` is pure and works in computed getters. `Time.now` is an impure host
read and is rejected inside computed evaluation.

`MochiFormat.timestamp(seconds, locale, timezone, options)` accepts numeric Unix
seconds with the same finite range. It converts to milliseconds at the Intl
boundary; browser Date truncates fractional milliseconds toward zero. Existing
`MochiFormat.date` continues accepting ISO strings, including its calendar-date
rules. Explicit locale/timezone determine presentation only. Neither operation
changes the instant. Use ordinary display bindings for host formatting.

The inspector retains exact integer millisecond timestamps for chronological
sorting, including its reverse-order toggle. Its Time conversion is only for
display; switching UTC/Tokyo preserves row order and selected ID. Fixtures use
fixed timestamps. Adapter tests inject a clock function; browser tests fix
`Date.now` without freezing timers, including pre-epoch and mount-time reads.

Time's Ruby package and stateless `mochi-time.js` adapter load only for consumers
and are ready before initialization. Formatting remains a separate optional
capability. Time objects use existing state roots and GC, without component
registration or new capacity knobs. A small shared VM constructor and native
bridges add an explicit [core payload cost](PAYLOAD_BUDGETS.md).

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

The inspector's complete class declares `ordered_records` as well as these
shared filtering/page projections:

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

See [InspectorRoot](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb) and
[projection reuse tests](../e2e/tests/gvm_computed.spec.ts). Paging reuses
filtering; unrelated selection/display state does not invalidate either method.

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

From [InspectorRoot](../e2e/fixtures/ui_contracts/lib/InspectorRoot.rb), whose
keyed row has `data-id="{record['id']}" onclick="{select_record($event)}"`:

```ruby
def select_record(event)
  @selected_id = event["current_target_dataset"]["id"]
end
```

[Event scenarios](../e2e/fixtures/ui_contracts/probes/08-event-dataset/test)
cover surfaces, descendants, shadow retargeting and payload-limit recovery.

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

## A single-dialog recipe

Keep the dialog's markup and keyboard behavior in a child component. Declare
the values the parent controls as typed props and keep confirmation and
cancellation as separate typed events:

```ruby
class ConfirmDialog
  @tag_name = "confirm-dialog"
  prop :title, String, required: true
  prop :message, String, required: true
  event :confirm, accepted: Boolean
  event :cancel, reason: String

  def mounted
    MochiShortcuts.register("Escape", "shortcut_cancel",
      {"scope" => "application", "active_ref" => "dialog", "prevent" => true, "allow_editable" => true})
    Mochi.focus("cancel")
  end

  def confirm
    emit("confirm", {"accepted" => true})
  end

  def cancel
    emit("cancel", {"reason" => "button"})
  end

  def shortcut_cancel(result)
    emit("cancel", {"reason" => "escape"}) if result["ok"]
  end

  def html
    %Q{
      <section ref="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title" tabindex="-1">
        <h2 id="dialog-title">{@title}</h2>
        <p>{@message}</p>
        <button ref="cancel" type="button" tabindex="0" onclick="{cancel}">Cancel</button>
        <button ref="confirm" type="button" tabindex="0" onclick="{confirm}">Confirm</button>
      </section>
    }
  end
end
```

The parent conditionally renders
`<confirm-dialog ref="dialog" tabindex="-1" data-mochi-focus-trap title="{@title}" message="{@message}" on:confirm="{confirm_dialog($event)}" on:cancel="{cancel_dialog($event)}"></confirm-dialog>`
and handles the two events independently. Call `Mochi.focus("dialog")` when
opening to save the opener; restore it when closing if it still exists, or focus
a stable fallback if the opener was removed. Put the trap on the child host so
the parent can capture opener focus while the trap also walks into the child's
shadow root. The child's named refs keep initial focus and Escape scoped to its
mounted lifetime. The built-in trap handles Tab and Shift-Tab. Use ordinary
interpolation for labels and user data so they remain text. [`Mochi.raw` is
trusted markup, not a sanitizer or a substitute for content projection](API_MIGRATIONS.md#trusted-markup-composition);
this pattern owns its markup and does not project parent content. Nested
dialogs, slots, and a general overlay manager are outside this recipe.

The [dialog fixture](../e2e/fixtures/ui_contracts/lib/ConfirmDialog.rb) and
[Ruby scenarios](../e2e/fixtures/ui_contracts/test/dialog_test.rb) cover typed
props/events, safe text updates, keyboard traversal, Escape, opener restoration,
and fallback focus after trigger removal.

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

Trusted markup occupies its authored text position without a framework-created
wrapper. SVG or other nodes can therefore be direct flex/grid children and
match direct-child selectors. Add an explicit HTML wrapper when you want to
style or lay out the fragment as one box. A value update replaces only the
nodes owned by that raw expression, leaving adjacent text and sibling DOM
identity intact. Mochi does not recompile trusted strings as templates:
placeholder text and event-looking attributes inside them do not create Ruby
bindings. Browser custom elements follow ordinary connect/disconnect behavior
when their containing raw range is inserted or removed; component tags inside
runtime strings do not add dependencies to the bundle.

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
the construct name and authored source location when the debug line maps to
authored code. Range bytecodes explain that array slicing uses
`array[start, length]`; this preserves Ruby's negative-index and exclusive
range semantics by leaving Range expressions unsupported. If generated code
has no exact authored span, the diagnostic says so and includes IREP/PC
context instead of inventing a source line. Ordinary method `return` and
supported while-loop `break`/`next` remain valid. The bare keyword `redo` is
not a valid handler method name. On opcode rejection, a temporary debug
compile supplies mrbc's line table; successful bundles contain no added debug
section.

This contract does not add arbitrary nested class/module registration,
constant inheritance/`const_missing`, or full Ruby exception and nonlocal
unwinding semantics. Essential scoped constant dispatch remains in the VM;
helpers continue to load as dependency-selected Ruby bytecode.

The inspector's [RecordData](../e2e/fixtures/ui_contracts/lib/RecordData.rb)
module supplies a filtering helper called by `RecordData.filter`:

```ruby
def self.filter(records, query)
  matches = []
  records.each do |record|
    next if !record["message"].include?(query)
    matches << record
  end
  matches
end
```

[Helper scenarios](../e2e/fixtures/ui_contracts/probes/03-helper-contexts/test/helper_test.rb)
also check nested loops and `map` with `next value` against native Ruby results.

## Browser capability ownership

Timers are mount-owned scheduling operations. See the
[timer contract](TIMER_CONTRACT.md) for callback names, delay and handle
validation, cancellation, disposal, and the Ruby polling example.

Capability packages and adapters load before their consuming component becomes
interactive. Registration APIs use static refs and Ruby callback names, not DOM
objects. From [EditableGraphRoot](../e2e/fixtures/ui_contracts/lib/EditableGraphRoot.rb):

```ruby
# Excerpt from mounted; the full class implements on_viewport and shortcut_undo.
MochiLayout.observe("viewport", "on_viewport")
MochiShortcuts.register("z", "shortcut_undo", {"ctrl" => true, "prevent" => true})
```

Its `stop_layout` method calls `MochiLayout.cancel("viewport")`; disposal cleans
up owned registrations automatically. The form registers Escape with
`scope: "application", active_ref: "dialog", allow_editable: true` so a removed
dialog cannot leave an active modal shortcut scope.

| Capability | Ownership and limit |
| --- | --- |
| [Pointer](POINTER_CONTRACT.md) | Captured bound targets belong to a component mount; capture loss/cancel/unmount clear gesture work. |
| [Layout](LAYOUT_CONTRACT.md) / [wheel](WHEEL_CONTRACT.md) | Static-ref measurement/observation and frame-batched input reject stale mounts and reconcile removed targets. No arbitrary DOM access or dynamic row refs. |
| [Shortcuts](SHORTCUT_CONTRACT.md) | Registrations follow focus/application scope and active refs; disposal removes them. Editable controls keep native behavior unless explicitly allowed. |
| [Files](DRAG_FILE_CONTRACT.md) | Handles/readers belong to one mount; close/cancel/unmount release resources and suppress late callbacks. Read one bounded chunk before requesting another. |
| [Downloads](DOWNLOAD_CONTRACT.md) | One bounded synchronous user-activation handoff. Accepted URL leases survive disposal until expiry; failures release immediately. Disk completion is not observable through this API. |

All callbacks and transport values follow their linked contracts. Registration
bounds do not make callbacks transactional: failed entries discard pending
patches/host commands but do not roll back prior Ruby state changes.

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
[`MochiMoney`](../AGENTS.md#money-helpers) for exact minor-unit accumulation.

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

## Ruby type inspection

`Object#is_a?(klass)` takes exactly one Class value and returns a Boolean. The
VM resolves these canonical built-in identities: `Object`, `Array`, `Hash`,
`Integer`, `Float`, `String`, `Symbol`, `TrueClass`, `FalseClass`, and
`NilClass`. Integer and Float stay distinct, including boxed wide Integers.
`Object` matches all supported Ruby values. User-defined classes retain their
existing ancestor checks.

Constant lookup keeps Ruby lexical and global constants ahead of built-in
fallbacks, so a local constant named `Integer` keeps its authored meaning.
Passing a non-Class value reports `type mismatch`; zero or multiple arguments
report `wrong number of arguments`. Both errors include the authored Ruby
location and leave later valid entries usable. The operation runs in the VM
without a host adapter or per-call wrapper allocation. Its behavior is covered
across initialization, component methods, template bindings and loops, event
handlers, qualified helpers, and typed Array/Hash props in the
[feedback fixture](../e2e/fixtures/feedback_review/lib/TypeInspection.rb).

## Array#unshift

`array.unshift` accepts zero through eight positional values, the VM's current
call argument limit. Values are inserted at the front in argument order, and
the method returns the same array:

```ruby
values = [3]
same_array = values.unshift(1, 2) # values and same_array are [1, 2, 3]
values.unshift                    # unchanged, returns values
```

The operation mutates its receiver. Aliases to the same array see the new
elements, and inserted elements retain shallow identity. Scratch values stored
in persistent arrays are promoted using the VM's existing state-copy rules;
declared Array props remain private snapshots, so mutating a child's prop does
not mutate the parent's array. Persistent collection writes keep their existing
binding notifications. Computed values still invalidate only when a declared
root changes; replace the owning root to publish nested edits to computed
projections. This method adds no automatic deep mutation observation.

Insertion uses the existing linked collection storage and bounded slot arenas.
Slot exhaustion reports the normal scratch/state capacity error. If a
multi-value call exhausts capacity after inserting some values, those earlier
mutations may remain; Mochi does not promise transaction rollback. No values
are silently dropped, and a later valid VM entry can continue.

See the [feedback fixture](../e2e/fixtures/feedback_review/lib/UnshiftRoot.rb)
for initialization, qualified-helper, event-handler, prop-isolation, and root
replacement examples.

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
