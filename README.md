<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/yampug/mochi/blob/main/github/assets/banner_dark.png?raw=true">
    <source media="(prefers-color-scheme: light)" srcset="https://github.com/yampug/mochi/blob/main/github/assets/banner_light.png?raw=true">
    <img alt="Mochi Banner" src="https://github.com/yampug/mochi/blob/main/github/assets/banner_light.png?raw=true">
  </picture>
</p>

[![License](https://img.shields.io/badge/license-MIT-green?labelColor=gray)](LICENSE.md)

## What is Mochi?

Mochi brings modern web development to [Ruby](https://www.ruby-lang.org/) by leveraging the excellent work from [Opal](https://opalrb.com/) and tighly coupling it with the open [Web Components](https://developer.mozilla.org/en-US/docs/Web/API/Web_components) standard.
Mochi provides also native [Sorbet](https://sorbet.org) support for all that type-checking goodness. This can normally be a bit daunting to get going yourself, since Sorbet doesn't play nice with Opal out of the box, so Mochi got your back.

So all in all Mochi brings type-safe Ruby to the modern web.
The project is still very early on its journey, so proceed at your own risk for now.

> **⚠️ Under Heavy Construction:**
> Mochi is currently under heavy development and is not yet ready for production use. APIs may change without notice, and features may be incomplete or unstable. Use at your own risk.


## Getting Started

If you want to get your hands dirty and try out Mochi for yourself, I prepared over at [yampug/mochi-starter-template](https://github.com/yampug/mochi-starter-template) a preconfigured starter template, which should make the first steps as easy as possible.

### Example Component
A simple example counter component with 2 buttons to increment and decrement the current count:

```ruby
class Counter

  @tag_name = "my-counter"
  @count

  def initialize
    @count = 0
  end

  def html
    %Q{
      <div class="wrapper">
        <h1>Count: {@count}</h1>
        <button onclick="{increment}">Increment</button>
        <button onclick="{decrement}">Decrement</button>
      </div>
    }
  end

  def css
    %Q{
      .wrapper {
        background: red;
      }
    }
  end

  def increment
    @count = @count + 1
  end

  def decrement
    @count = @count - 1
  end

  def mounted
    puts "Counter mounted"
  end

  def unmounted
    puts "Counter unmounted"
  end
end

```

### Shared component styles

A component `css` body still starts as one literal string. It may reference
shared CSS files with build-time `@import` rules:

```ruby
def css
  %Q{
    @import "../styles/reset.css";
    @import "../styles/controls.css";
    :host { display: block; }
    .btn { padding: 9px 14px; }
  }
end
```

Imports resolve relative to the component file, recursively, depth-first in
source order. `@import` rules must come before local CSS. The component's own
rules are applied last, so a local override wins. A shared fragment is emitted
once by stable content identity even when several components import it; the
manifest records each fragment's stable identity and file location, and each
component descriptor lists its ordered `style_resources`. The loader fetches a
shared fragment only when a component that owns it first mounts.

The compiler rejects missing fragments, import cycles, unclosed blocks,
unclosed strings or comments, invalid import syntax, and `#{...}`
interpolation with the component or fragment path and line. CSS is never
executed or fetched at runtime. Shadow roots use constructable stylesheets when
available and an ordered `<style>` fallback otherwise. CSS custom properties
still inherit from the document into both paths.

### Icons

Put only the SVG assets the app may use in an `icons/` directory at the project
root. Each file is a normal SVG with `id="mochi-icon"`. Render it from Ruby:

```ruby
def html
  %Q{
    <button>{Mochi.raw(MochiIcons.icon("settings"))} Settings</button>
  }
end
```

`MochiIcons.icon` returns inline `<svg><use ...></svg>` markup, so
`currentColor` and inherited theme tokens keep working. The build emits only
icons named by `MochiIcons.icon("...")` or a matching source string into
`mochi-icons/`. Missing referenced assets fail the build with the component
source location. No CDN or global Feather object is required. `Mochi.raw` is
still required because ordinary template values stay text.

### Trusted markup

Template values are text by default, whether they stand alone, sit inside a
sentence, or come from an `each` row. A string containing `<b>`, quotes, or an
event-handler attribute is displayed literally.

Use `Mochi.raw(expression)` when an app-authored value intentionally contains
markup, such as an inline SVG icon:

```ruby
def html
  %Q{
    <span class="icon">{Mochi.raw(MochiIcons.icon("settings"))}</span>
    <span>Status: {@status}</span>
  }
end
```

`Mochi.raw` is a compilation-time escape hatch, not a sanitizer. Only wrap
markup your app authored or already trusts. It is accepted in text content,
including list rows, and rejected in attribute values. Values without it never
create elements or event handlers.

### List rows

Rows keep their DOM identity while their values change. Use an explicit Ruby
key expression when the item does not already expose a stable `key` or `id`
field:

```ruby
def html
  %Q{
    <ul>
      {each @events as event, index, key: event["id"]}
        <li>
          <input class="draft">
          <span>{event["label"]} at {index}</span>
        </li>
      {end}
    </ul>
  }
end
```

The key expression runs inside the VM, not in the browser. Rows whose keys
match existing rows patch their text, attributes, trusted markup, and nested
rows in place, so drafts, focus, selection, and child component state survive
updates and moves.
Insertions and removals preserve the surviving rows; removed rows dispose once.
When no explicit key is given, the loader uses an item `key` field, then an
`id` field, and otherwise uses the row position as identity. Duplicate keys
fail with a source-located error before the list changes.

### Attributes and form state

Interpolated attributes evaluate their Ruby expression in the VM. Attribute
values never create markup: `Mochi.raw` is rejected inside an attribute, and a
string such as `<b>` or `onclick="..."` is stored as text.

Mochi distinguishes three attribute categories:

* **Textual attributes** keep the authored string, including `"false"`, `"0"`,
  and the empty string. This includes `aria-*`, `data-*`, `class`, `title`,
  `href`, and every attribute that is not an HTML boolean attribute.
* **Boolean attributes** such as `disabled`, `checked`, `hidden`, `required`,
  `readonly`, `selected`, and `open` are present or absent. The presence of
  `true` keeps the attribute; `false`, `nil`, and the empty string remove it.
* **Live form properties** are compiled from `bind:value` and `bind:checked`.
  They update the DOM property without replacing the input, so an unrelated
  update keeps the node, draft, focus, and selection.

```ruby
def html
  %Q{
    <input type="text" bind:value="@query">
    <input type="checkbox" bind:checked="@enabled">
    <button disabled="{@enabled}" aria-expanded="{@expanded}">Filter</button>
    <span data-count="{@count}" title="{@note}">rows</span>
  }
end
```

`aria-expanded="false"` stays a textual `"false"` value, while
`disabled="false"` removes `disabled`. A value of `0` renders as `"0"`, never
as absence. A `nil` result removes an attribute whose value is exactly one
placeholder; an empty string keeps that textual attribute present and empty.
When the attribute also contains literal text, `nil` contributes nothing and
the attribute remains. In text content, `nil` and the empty string both render
no characters. `bind:value` writes `nil` and the empty string as an empty value
without replacing the input; `bind:checked` checks only for `true`, `"true"`,
`"checked"`, or `"1"`.

### Live component attributes

Attributes on a child component element are its props. The loader writes every
current attribute into the child instance; a later change to the attribute,
including one produced by a parent binding, updates the mounted child in place.
The child keeps its Ruby instance, bindings, and DOM nodes.

```ruby
def html
  %Q{<child-badge label="{@label}"></child-badge>}
end
```

The setter reports `0` for success and `-1` for failure. A failure is reported
as a `mochi:error` with `phase: "attribute"` plus the failing `attribute` and
`property`, instead of being treated as a successful no-op. Re-writing the
current value is a successful no-op and produces no patch, so an observer that
echoes the attribute cannot start an update loop.

Attributes without a declaration keep the historical string behavior,
including removal writing an empty string. Declare a prop to receive a real
Ruby value instead.

### Declared typed props

Declare inputs in the component class body:

```ruby
class ChildBadge
  @tag_name = "child-badge"
  prop :label, String, default: "unset"
  prop :count, Integer, default: 0
  prop :enabled, Boolean, default: false
  prop :note, String
  prop :rows, Array, default: []
  prop :meta, Hash, default: {}

  def initialize
    @summary = "#{@label}:#{@count}"   # defaults are already installed
  end

  def html
    %Q{<span>{@label}</span><span>{@count}</span><span>{@rows.length}</span>}
  end
end
```

Supported types are `String`, `Integer`, `Float`, `Boolean`, `Array`, and
`Hash`. A declaration can be `required: true` or provide `default:`, but not
both. Default expressions may be literals or constants. The compiler rejects
unknown types, duplicate names, an unknown option, and a default whose literal
type does not match the declaration.

The loader resolves declared props before it creates the VM instance. A missing
required input or a value that does not match its type aborts the mount with a
`mochi:error` naming the prop, the component, and the declaration's source
location. Nothing is partially mounted.

HTML text maps to Ruby as follows:

| Declared type | Attribute text | Ruby value |
| --- | --- | --- |
| `String` | any text | that string, including `""` |
| `Integer` | `-?[0-9]+` inside the signed 64-bit range | `Integer` |
| `Float` | decimal text such as `0.5` or `1e-3`, `Infinity`, `-Infinity`, or `NaN` | `Float` |
| `Boolean` | `true`, `false`, or `""` (HTML presence) | `true` or `false` |
| `Array` | JSON array text | a new Ruby `Array` |
| `Hash` | JSON object text | a new Ruby `Hash` |

### Numbers

Ruby `Integer` is a checked signed 64-bit value. The VM keeps values that fit
in 32 bits as immediates and boxes wider integers without changing their
observable range. Ruby `Float` is a binary64 value, including `Infinity` and
`NaN` where an operation produces them. Integer division stays integer
division: `1 / 2` is `0`, while `1.0 / 2` is `0.5`. Mixed comparisons and
arithmetic promote the integer operand to `Float`.

Checked integer overflow, integer division by zero, and unsupported numeric
operations stop the entry with a `mochi:error` instead of wrapping or
truncating. The error names `integer overflow`, `division by zero`, or
`type mismatch` and includes the Ruby method's source location. Floating-point
division by zero follows IEEE 754 and produces `Infinity` or `NaN`, matching
Ruby.

Values crossing the browser boundary keep exact integers above JavaScript's
2^53 exact-number range. Props and child-event payloads use a typed number
transport instead of a raw JSON number, and the loader validates the signed
64-bit range before the VM sees it. Integers that fit safely still travel as
ordinary JSON numbers on the JavaScript side. Floats render with Ruby's
shortest round-trip spelling, including a `.0` mantissa; locale-aware decimal
formatting belongs to the component, not the numeric core. For exact multi-step
money work, use the [money helpers](#money-helpers) and round once at display
time. For locale-aware labels, use the [formatting helpers](#number-and-date-formatting).

Absence is `nil`, distinct from `""`, `0`, and `false`. Removing a declared
attribute installs `nil`; removing a required attribute is an error. A single
`{expression}` attribute value is a parent binding that has not produced a value
yet, so it is treated as pending rather than as literal text. Collection values
are decoded with `JSON.parse` by the loader but arrive in Ruby as real arrays and
hashes, so component code does not parse JSON.

Declared props are read-only snapshots:

- Defaults and supplied values are installed before `initialize`, so the
  constructor can read them.
- They are installed again after `initialize` from an independent copy. An
  assignment or in-place collection mutation in `initialize` cannot overwrite
  the parent's input. Put derived state in its own ivar.
- Each replacement is a private deep copy. A child that mutates a passed array
  or hash cannot change the parent's data. Send the new value back through an
  event when the parent should change.
- All changed declared props from one observer batch travel in one typed VM
  entry and produce one patch flush, so two related inputs never expose an
  intermediate inconsistent render.
- Replacing a collection releases the previous snapshot through the VM's
  normal reclamation; repeated parent updates stay bounded.

Migration from undeclared attributes: add a `prop` declaration for each input
the child reads, give it a default when absence should have one, then remove the
child's `to_i`, boolean checks, and manual `JSON.parse`. Leave attributes that
are deliberately string-only undeclared.

### Money helpers

Money is application data, not part of the numeric core. When a source mentions
`MochiMoney`, the compiler emits a small exact-money Ruby dependency package.
Applications that never mention it do not receive the file.

A ledger is an ordinary Ruby `Hash` holding an exact `numerator / denominator`
number of minor units. The helper never rounds during aggregation. Choose the
scale with the denominator you add. For example, a rate in cents per million
tokens contributes `tokens * rate / 1_000_000` cents:

```ruby
cost = MochiMoney.ledger
MochiMoney.add_ratio(cost, 202_000 * 300, 1_000_000)

MochiMoney.exact(cost)          # "303/5" (60.6 cents)
MochiMoney.round_half_up(cost)  # 61
```

`add_minor(ledger, 25)` adds 25 whole minor units. `merge(ledger, other)` adds
another ledger exactly, and `apply_ratio(ledger, numerator, denominator)`
scales it exactly. `numerator(ledger)`, `denominator(ledger)`, and
`exact(ledger)` expose the reduced value. `MochiMoney.amount(numerator,
denominator)` and `MochiMoney.minor(amount)` create a ledger for one value.

Round only at the display boundary. The named modes are:

| Method | Rule |
| --- | --- |
| `round_half_up` | nearest; exact halves away from zero |
| `round_half_down` | nearest; exact halves toward zero |
| `round_half_even` | nearest; exact halves to the even integer |
| `round_floor` | toward negative infinity |
| `round_ceil` | toward positive infinity |
| `round_truncate` | toward zero |

Negative adjustments are ordinary negative numerators. For `-1/2` of a minor
unit, `round_half_up` and `round_floor` return `-1`; `round_half_down`,
`round_half_even`, `round_ceil`, and `round_truncate` return `0`. Currency
display normally uses `round_half_up`, matching `Intl.NumberFormat`'s default
currency rounding.

Do not round each line and then sum the labels. Three charges of `2/5` of a
cent sum exactly to `6/5`; `round_half_up` gives `1`, while rounding each line
gives `0`. Likewise, displayed model labels can differ from a displayed total
by one minor unit. Derive every total from the same exact ledgers and account
for the display difference explicitly rather than feeding rounded labels back
into the pipeline.

All arithmetic uses the checked signed 64-bit integer operations. A
cross-product or scale that does not fit reports `integer overflow` through the
normal `mochi:error` channel. A zero denominator reports `division by zero`.
The minimum signed 64-bit value remains exact while its denominator is
positive; an operation that would negate it reports overflow.

The helper performs no currency symbols, grouping, decimal separators, or
locale lookup. Format the integer returned by a `round_*` method in your
component. Applications that do not use `MochiMoney` pay no bytes for it; the
compiler attaches the helper package to the components that depend on it.

### Number and date formatting

`MochiFormat` formats numbers and dates from ordinary Ruby. It works in
`initialize`, component methods, binding expressions, event handlers, and each
rows. Application authors do not write JavaScript and do not choose a
formatter library.

```ruby
MochiFormat.decimal(1_234_567.89, "en-US", {"maximum_fraction_digits" => 2})
# "1,234,567.89"

MochiFormat.decimal(1234.5, "de-DE")
# "1.234,5"

MochiFormat.currency(123_456, "USD", "en-US", 2)
# "$1,234.56"

MochiFormat.compact(1_234_567, "en-US")
# "1.2M"

MochiFormat.percent(0.42, "en-US")
# "42%"

MochiFormat.date("2026-10-11", "en-US", "UTC", {"month" => "short", "day" => "numeric"})
# "Oct 11"

MochiFormat.date("2026-11-09T23:30:00Z", "en-US", "Asia/Tokyo",
                {"date_style" => "medium", "time_style" => "short"})
# "Nov 10, 2026, 8:30 AM"
```

The signatures are:

| Helper | Arguments |
| --- | --- |
| `number(value, locale = "en-US", options = {})` | grouped decimal number |
| `decimal(value, locale = "en-US", options = {})` | alias for `number` |
| `currency(minor_units, currency = "USD", locale = "en-US", scale = 2, options = {})` | exact integer minor units |
| `compact(value, locale = "en-US", options = {})` | short labels such as `1.2M` |
| `percent(value, locale = "en-US", options = {})` | ratio, so `0.42` becomes `42%` |
| `date(iso, locale = "en-US", timezone = "UTC", options = {})` | ISO date or timestamp |

Arguments are positional. `options` is an ordinary Ruby `Hash`; its keys are
the `Intl` option names written in snake case, such as
`maximum_fraction_digits` or `date_style`. Unsupported keys, invalid locales,
and invalid option values stop the entry with a `mochi:error` that names the
Ruby helper and the offending value. The default location for a timestamp is
UTC. A date-only value such as `2026-10-11` is a calendar date and must use UTC;
pass a full timestamp to format another timezone. Locale and timezone defaults
are fixed so a label does not change with the machine's settings.

`currency` takes an exact number of minor units and divides by `10^scale` at
the display boundary. It accepts values up to
1,000,000,000,000,000 minor units; larger values report an error instead of
silently returning an imprecise JavaScript number. Use the
[money helpers](#money-helpers) for multi-step arithmetic and pass the rounded
minor-unit total to `currency`.

Formatting uses the browser's built-in `Intl` facilities through an optional
host adapter. The compiler writes `mochi-format.js` and records the
`formatting` capability in `mochi-manifest.json` only when a reachable Ruby
package owns `MochiFormat`. The manifest entry names the adapter, its version,
and the `format` operation as `sync`. The loader requests the adapter before
mounting a component whose dependency closure includes the capability and
validates the adapter's name, version, and operation table before installing
it. A component or application that does not use formatting neither ships nor
requests it. The bundle contains no locale database. If the adapter is missing,
fails to load, or registers a different version or operation, the mount fails
with a Ruby-facing `mochi:error` that names the component and capability instead
of an unknown-method failure. Formatter instances are cached by locale and
options, with a bounded cache so a long-lived application cannot grow it
without limit.

### Host capability adapters

Optional Ruby capabilities that need browser facilities use one internal
adapter contract. Application code still calls ordinary Ruby APIs such as
`MochiFormat`; it never writes a promise, imports a JavaScript module, or adds a
script tag. The compiler and loader own the adapter lifecycle.

A manifest capability record has this shape:

```json
"capabilities": {
  "formatting": {
    "version": 1,
    "host": "mochi-format.js",
    "operations": { "format": "sync" },
    "packages": ["ruby:lib/mochi_builtin_format.rb"]
  }
}
```

The adapter is a local build artifact named by the manifest. It registers
itself with the loader while its script runs:

```js
MochiHostAdapter.register({
  name: "formatting",
  version: 1,
  sync: {
    format: function (argsJson) { /* return one typed JSON value */ }
  }
  // async: { operation: function (argsJson) { return Promise.resolve(value); } }
});
```

Synchronous operations receive one JSON argument array and return one typed
JSON value, including strings, numbers, booleans, arrays, and hashes. The VM
dispatches only a declared capability and operation; it never evaluates
JavaScript supplied by application code. Asynchronous operations return a
promise. Their result reaches the Ruby caller through the documented callback
Hash `{ok:, value:, error:}`, carrying the requesting instance and mount
attempt. A completion that arrives after unmount or after a replacement mount
is dropped, and unmount removes the pending request. Unknown capability names,
unsupported versions, undeclared operations, and adapter load failures are
explicit errors.

The fixed capability dispatch bridge is part of the core WASM artifact because
the VM must be able to call a registered adapter synchronously. Splitting
`.chi` files or adapters does not remove that small bridge from the WASM; only
the adapter implementation itself is omitted for applications that do not
declare the capability.

### Synchronous event modifiers and focus

Native event attributes can carry synchronous modifiers after dots:

```html
<a href="/save" onclick.prevent.stop.self="{save}">Save</a>
```

- `prevent` calls `preventDefault()` during the browser dispatch.
- `stop` calls `stopPropagation()` during the browser dispatch.
- `self` runs the handler only when the event target is the element carrying the attribute.

The loader applies these before it queues Ruby work, so a cancelable link or
submit default is already prevented when Ruby observes the event. A
non-cancelable event ignores `prevent` without an error. Modifiers also work on
`on:<event>` connections; `self` is meaningful there, while `prevent` and `stop`
only affect native events.

Handler payloads stay plain Ruby hashes. A native event adds normalized target
metadata without exposing a DOM node:

```ruby
def on_key(event)
  event[:key]                       # "Escape"
  event[:target][:tag]              # "button"
  event[:target_ref]                # "modal_close"
  event[:current_target][:id]       # handler element id
  event[:composed_path].map { |node| node[:tag] }
end
```

The payload includes `target`, `current_target`, `target_ref`, `target_tag`,
`current_target_ref`, `current_target_tag`, `current_target_id`, and
`composed_path`. Path entries contain only `tag`, `id`, `ref`, and `component`
labels.

Static elements can declare a component-local name with `ref`:

```html
<div class="panel" data-mochi-focus-trap>
  <button ref="first">First</button>
  <button ref="last">Last</button>
</div>
```

```ruby
Mochi.focus(:first)       # remembers the current focus, then focuses "first"
Mochi.restore_focus       # returns to the last remembered focus
```

Ref names are static, unique within one component, and not supported inside
`each` rows. A missing or detached target reports `mochi:error` with
`phase: "focus"` and `reference`. `data-mochi-focus-trap` keeps Tab and
Shift-Tab inside the marked element and is evaluated by the loader, so no
application JavaScript is required. Focus capture walks into open shadow roots
and restores the actual focused element, not only its host.

### Scoped child events

A reusable child declares the events it can emit in the class body:

```ruby
class EventRow
  @tag_name = "event-row"
  event :select, id: Integer, label: String
  event :opened

  def html
    %Q{<button onclick="{choose}">Choose</button>}
  end

  def choose
    emit :select, id: 7, label: "Seven"
  end
end
```

Payload fields use `lower_snake_case` and support `String`, `Integer`, `Float`,
`Boolean`, `Array`, and `Hash`. Integer fields use the signed 64-bit range, and
large values keep exact transport as described in [Numbers](#numbers). The
payload is a fixed contract: every declared
field is required, unknown fields are rejected, and values are checked against
the declaration. `emit :opened` sends an empty payload. A component with
declared events cannot define its own `emit`.

A parent binds the connection with `on:<event>`, not a DOM `on<event>`
attribute:

```html
<event-row on:select="{row_selected($event)}"></event-row>
```

The compiler records the connection and emits `data-mochi-select` on the child
element. The loader routes the emitted event to the exact mounted child
instance that emitted it, then the parent's generated handler runs. Two
`<event-row>` instances with the same tag can bind to different parents or
handlers. `$event` is the typed payload; if the handler takes one argument, the
payload is passed automatically.

Removing a child or row cancels queued deliveries for that instance. A stale
event from a removed instance is dropped rather than delivered to a
replacement. Payload contract failures are reported as `mochi:error` with
`phase: "event"`, `event`, `payloadKey`, and the `event` declaration's source
location; the parent handler does not run.

`Mochi.emit(action, payload)` remains the explicit application-wide broadcast.
It sends a `mochi:action` to every mounted component implementing `action`;
pass `target:` to limit it to components with that tag. Use it for genuinely
app-wide notifications, not for ordinary parent/child communication.

### Component lifecycle

Moving a connected component between positions in the same turn preserves its Ruby instance, state, timers, and event handlers; `unmounted` and `mounted` do not run again. If the element stays disconnected through that turn, the loader disposes it once and runs `unmounted`. Reinserting it afterwards performs a fresh mount from `initialize`, rebuilding props, bindings, and handlers.

### Compiling
Prerequisites:
* <img alt="Crystal Icon" style="height: 16px;" src="https://crystal-lang.org/favicon.ico"/> [Crystal](https://crystal-lang.org/)
* <img alt="Task Go Icon" style="height: 16px;" src="https://github.com/yampug/mochi/blob/main/github/assets/task_icon.ico?raw=true"> [Task](https://taskfile.dev)
* Prebuilt C libraries in `fragments/libs` (see [docs/BUILD_INSTRUCTIONS_EXT_LIBS.md](docs/BUILD_INSTRUCTIONS_EXT_LIBS.md))
* Node.js for the Playwright end-to-end test
* Emscripten only when rebuilding the `mochi-gvm` WASM artifact

```
git clone http://github.com/yampug/mochi
cd mochi
task run
```

The Crystal compiler emits a `mochi-gvm` bundle: `mochi-gvm.wasm`, `mochi-gvm.js`, `mochi-loader.js`, `mochi-manifest.json`, one `.chi` file and one descriptor JSON file per component, one `.chi` file per Ruby dependency package, and separate files for shared styles and requested icons. It also writes one local JavaScript adapter per host capability that a reachable package declares; today that is `mochi-format.js` only when a reachable package uses `MochiFormat`. It does not generate component-specific JavaScript.

`mochi-manifest.json` is the compact entry index for the bundle. It records a `schema_version` for the bundle format and lists each component's identity, dependency package, and descriptor location. Templates, local styles, bindings, props, and events live in the per-component descriptor instead of the entry manifest. A loader that does not support the bundle schema fails before it runs Ruby bytecode, and a descriptor whose schema does not match the entry manifest fails with the component name. Each component descriptor names its dependency package, and every package records the Ruby files, shared helpers, styles, and optional capabilities it owns. An optional capability is a versioned record with a local adapter location and an explicit table of synchronous or asynchronous operations. The compiler builds this graph from literal `require` and `require_relative` calls, component tags used in templates, and the package that exports each referenced Ruby constant. Dynamic loading such as `load`, `autoload`, or an interpolated require path stops the build with the Ruby source location. Missing and duplicate dependencies also stop the build. Dependency order is sorted and reproducible, and package identities do not contain checkout paths.

`task payload` builds the checked-in minimal and optional-feature fixtures twice, verifies byte-identical artifacts, audits the generated file sets against the manifest, rejects unused adapters and styles, and enforces raw and gzip ceilings. It does not run a benchmark or collect runtime metrics. Exact inputs, baselines, and the budget update policy live in [references/PAYLOAD_BUDGETS.md](references/PAYLOAD_BUDGETS.md). Browser tests separately prove that an unused adapter and its Ruby package are never requested, while a used feature loads each resource once.

On first use, the loader fetches that component's descriptor, its shared style files, its host adapters, and its dependency closure before mounting. Descriptor, package bytecode, style text, registered host adapters, and parsed template data are cached immutably, while every component instance keeps its own VM state. Concurrent instances share one request per resource, failed downloads are evicted so a reconnect can retry, and a component removed during loading is never mounted. Adapter loading failures name the component and capability instead of falling back to a global script or arbitrary JavaScript evaluation.

### Compiler Tasks

| Task | Description |
|---|---|
| `task run` | Build the compiler and compile `compiler/motestproj` into `build_gvm` |
| `task build` | Build the `compiler/mochi` binary |
| `task specs` | Run the Crystal compiler specs |
| `task typecheck` | Typecheck the motestproj components with Sorbet |
| `task e2e` | Run the GVM Playwright end-to-end test |
| `task dev` | Build motestproj and serve `build_gvm` on port 27490 |
| `task gvm:test` | Run the `mochi-gvm` Goose test suite |
| `task gvm:fmt` | Check `mochi-gvm` Goose formatting |
| `task gvm:wasm` | Rebuild the `mochi-gvm` WASM and JS artifacts |
| `task generate-batteries` | Regenerate the built-in battery sources |
| `task runtime:test` | Run the loader and host adapter Node tests |
| `task payload` | Check deterministic bundle membership and payload ceilings |
| `task check` | Run runtime tests, compiler specs, payload checks, GVM tests, and the GVM end-to-end test |

### Usage

#### Creating a new project
```
mochi --initialize="my_fancy_project"
```

#### Compiling your code
```
mochi -i "/path/to/my/beautiful/ruby_code" -o "/path/where/I/want/to/output" --typecheck
```

* -i: input directory
* -o: output directory
* --typecheck: Run Sorbet typechecks (optional)
* --initialize: Creates a new preconfigured project directory

The output is a ready-to-serve GVM bundle. Load `mochi-loader.js` from your entry page; the loader reads the entry manifest, checks its schema version, registers the component identities, and fetches a component's descriptor, dependency packages, shared styles, and `.chi` file when that component first connects.



## License

[MIT](LICENSE.md)
