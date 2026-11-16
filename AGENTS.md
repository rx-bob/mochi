# Required Reading

Before working on Mochi, read [references/MOTTO.md](references/MOTTO.md). It is the project's north star and must guide design, implementation, review, and prioritization decisions.

Mochi must provide a complete Ruby developer experience without requiring JavaScript, while keeping the core and shipped payloads very small through optional capabilities and on-demand loading.

# Working on Mochi

Keep the [README](README.md) focused on getting started. Detailed component,
API, runtime, and contributor guidance lives here and in the linked references.
The sections below describe the current implementation and its contracts.

## Guide index

- [Ruby task guide](references/RUBY_TASK_GUIDE.md): timers, storage, downloads, events, datasets, shortcuts, and screen lifetime recipes
- [Build from source](#building-mochi-from-source), [tasks](#compiler-tasks), and [CLI / development installation](#cli-reference)
- [Complete Ruby examples and contracts](#complete-ruby-examples-and-contracts)
- [Shared styles](#shared-component-styles), [public assets](#public-assets), and [icons](#icons)
- [Trusted markup](#trusted-markup), [list rows](#list-rows), and [form state](#attributes-and-form-state)
- [Live attributes](#live-component-attributes) and [typed props](#declared-typed-props)
- [Numbers](#numbers), [money](#money-helpers), and [formatting](#number-and-date-formatting)
- [Host capability adapters](#host-capability-adapters)
- [Mount-owned timers](references/TIMER_CONTRACT.md)
- [Event modifiers and focus](#synchronous-event-modifiers-and-focus), [child/global events](#scoped-child-events), and [lifecycle](#component-lifecycle)
- [Routing](#routing-and-history) and [storage](#storage-and-subscriptions)

## Building Mochi from source

For application setup, follow the [README quickstart](README.md#getting-started).
To build Mochi itself, install these prerequisites:

* [Crystal](https://crystal-lang.org/) and [Task](https://taskfile.dev)
* Ruby for the development installer and Ruby test recorder
* Node.js for runtime and Playwright tests
* Prebuilt libraries in `fragments/libs` (see [external library setup](docs/BUILD_INSTRUCTIONS_EXT_LIBS.md))
* Compatible `mrbc` and GVM runtime artifacts; Emscripten is needed only to rebuild the GVM WASM runtime

```
git clone https://github.com/yampug/mochi
cd mochi
task build
task install:dev
```

The Crystal compiler emits a `mochi-gvm` bundle: `mochi-gvm.wasm`, `mochi-gvm.js`, `mochi-loader.js`, `mochi-manifest.json`, one `.chi` file and one descriptor JSON file per component, one `.chi` file per Ruby dependency package, and separate files for shared styles and requested icons. It also writes a local adapter for each reachable host capability: formatting, time, network, layout, shortcuts, pointer, drag, files, or download. Pure Ruby/VM capabilities such as JSON need no host adapter. Unused optional packages and adapters are omitted. It does not generate component-specific JavaScript.

`mochi-manifest.json` is the compact entry index for the bundle. It records a `schema_version` for the bundle format and lists each component's identity, dependency package, and descriptor location. Templates, local styles, bindings, props, and events live in the per-component descriptor instead of the entry manifest. A loader that does not support the bundle schema fails before it runs Ruby bytecode, and a descriptor whose schema does not match the entry manifest fails with the component name. Each component descriptor names its dependency package, and every package records the Ruby files, shared helpers, styles, and optional capabilities it owns. An optional capability is a versioned record with a local adapter location and an explicit table of synchronous or asynchronous operations. The compiler builds this graph from literal `require` and `require_relative` calls, component tags used in templates, and the package that exports each referenced Ruby constant. Dynamic loading such as `load`, `autoload`, or an interpolated require path stops the build with the Ruby source location. Missing and duplicate dependencies also stop the build. Dependency order is sorted and reproducible, and package identities do not contain checkout paths.

`task payload` builds the checked-in minimal and optional-feature fixtures twice, verifies byte-identical artifacts, audits the generated file sets against the manifest, rejects unused adapters and styles, and enforces raw and gzip ceilings. It does not run a benchmark or collect runtime metrics. Exact inputs, baselines, and the budget update policy live in [references/PAYLOAD_BUDGETS.md](references/PAYLOAD_BUDGETS.md). Browser tests separately prove that an unused adapter and its Ruby package are never requested, while a used feature loads each resource once.

On first use, the loader fetches that component's descriptor, its shared style files, its host adapters, and its dependency closure before mounting. Descriptor, package bytecode, style text, registered host adapters, and parsed template data are cached immutably, while every component instance keeps its own VM state. Concurrent instances share one request per resource, failed downloads are evicted so a reconnect can retry, and a component removed during loading is never mounted. Adapter loading failures name the component and capability instead of falling back to a global script or arbitrary JavaScript evaluation.

## Compiler Tasks

| Task | Description |
|---|---|
| `task run` | Build the compiler and compile `compiler/motestproj` into `build_gvm` |
| `task build` | Build the `compiler/mochi` binary |
| `task specs` | Run the Crystal compiler specs |
| `task lint` | Lint the explicit positive project inventory with the shipped default policy |
| `task typecheck` | Typecheck the motestproj components with Sorbet |
| `task framework:e2e` | Run portable framework browser regressions, including all UI fixtures |
| `task framework:ui` | Run UI fixtures, feedback evidence, and related regressions in all three engines |
| `task e2e` / `task app:e2e` | Run the separate Cowboy application integration (requires that checkout) |
| `task dev` | Build motestproj and serve `build_gvm` on port 27490 |
| `task gvm:test` | Run the `mochi-gvm` Goose test suite |
| `task gvm:fmt` | Check `mochi-gvm` Goose formatting |
| `task gvm:wasm` | Rebuild the `mochi-gvm` WASM and JS artifacts |
| `task generate-batteries` | Regenerate the built-in battery sources |
| `task runtime:test` | Run the loader and host adapter Node tests |
| `task payload` | Check deterministic bundle membership and payload ceilings |
| `task check` | Run compile-time gates, runtime tests, compiler specs, project lint, payload checks, GVM tests, and portable framework browser tests |

## CLI reference

### Installing the development command

From the Mochi checkout, run `task install:dev`. This builds the compiler and
installs a checkout-backed `mochi` launcher under `~/.local/bin`, plus a
resource record under `~/.local/share/mochi`. Set `MOCHI_INSTALL_PREFIX` to use
another prefix, for example:

```sh
MOCHI_INSTALL_PREFIX="$HOME/Tools/mochi dev" task install:dev
```

The installer prints the `PATH` entry to add when needed. It does not edit shell
startup files. `task install:dev:update` refreshes an owned launcher and record;
`task install:dev:remove` removes only those owned files. Installer refuses to
replace an unrelated `mochi` executable. Running `ruby
scripts/install_dev.rb --prefix PATH` from the checkout offers the same install
operation.

Resource lookup order is explicit environment override, installed resource
record, then known paths in the Mochi checkout (including its built
`build_wasm/mruby` compiler), followed by the sibling `../mochi-gvm` checkout.
The compiler supports `MOCHI_COMPILER`, `MRBC`,
`MOCHI_GVM_DIR`, `MOCHI_GVM_WASM`, `MOCHI_GVM_JS`, `MOCHI_LOADER`,
`MOCHI_FORMAT_HOST`, `MOCHI_HOST_ADAPTER_MOCHI_FETCH_JS`, and
`MOCHI_E2E_NODE_MODULES`. A bad explicit path stops
the operation; it never falls through to another resource. The launcher sets
`MOCHI_INSTALL_RECORD` for its installation. Builds validate required files,
WebAssembly format, loader manifest schema, and installed compiler/runtime
identity before changing output. The loader checks the capacity fingerprint
embedded in the runtime against the bundle manifest before runtime
initialization. See [fixed VM capacities](docs/fixed-capacities.md) for the
build-time profile format and custom artifact workflow.

* `mochi --initialize=PROJECT` creates the generated Ruby project.
* `mochi -i INPUT -o OUTPUT [--typecheck]` builds an application bundle.
* `mochi lint -i PROJECT [--format=json]` checks the project's Ruby sources and exits nonzero for any reported diagnostic.
* `mochi test -i PROJECT [--browsers=chromium,firefox,webkit|all] [--test-file=FILE]` runs Ruby behavior tests; `FILE` is an existing `*_test.rb` path relative to `test/`.
* `mochi dev --config=FILE --root=DIR` serves a local project.

The output is a ready-to-serve GVM bundle. Load `mochi-loader.js` from the
entry page; it validates the manifest and fetches a component's descriptor,
dependency packages, shared styles, and `.chi` file when that component first
connects.

## Complete Ruby examples and contracts

The [shared UI fixtures](e2e/fixtures/ui_contracts/README.md) provide portable
applications: a 480-record paginated inspector with filtered JSONL/CSV downloads,
a keyed SVG graph with drag/zoom/undo, a nested form with local drafts, and a
typed single-dialog recipe with keyboard focus behavior. Their authored
scenarios use `mochi test`; no application JavaScript or external service is needed.

Run `task framework:ui` for all three engines, or `task framework:ui:inspector`,
`task framework:ui:graph`, and `task framework:ui:form` for one slice. See the
[current evidence inventory](references/UI_FIXTURE_CONTRACTS.md) for each
feedback report's supported behavior or explicit limitation.

[Ruby surface](references/RUBY_SURFACE.md) documents array slicing, qualified
helpers and block `next`, explicit computed dependencies and root replacement,
binding-before-handler order, and target versus handler datasets. Optional
[layout](references/LAYOUT_CONTRACT.md), [wheel](references/WHEEL_CONTRACT.md),
[shortcuts](references/SHORTCUT_CONTRACT.md), and
[downloads](references/DOWNLOAD_CONTRACT.md) retain owned lifetimes. They load
before their component becomes interactive and are omitted when unused.
The core [timer contract](references/TIMER_CONTRACT.md) documents delayed and
repeating Ruby callbacks with automatic mount cleanup.

[Files](references/DRAG_FILE_CONTRACT.md#bounded-byte-streaming) support bounded
whole reads (48,000 bytes by default) and one-at-a-time binary chunks (8,192
bytes). Larger files do not imply a larger whole-file Ruby String. Handles and
readers belong to their mount; cancellation/disposal releases them and suppresses
stale callbacks. [Capacity configuration](docs/fixed-capacities.md) explains
fixed bounds and failure/recovery without promising state rollback.

Full MRI/Regexp/Date/Math coverage, slots, SVG custom-element composition,
automatic deep mutation observation, arbitrary DOM access, general import/export
products, and reusable graph/form libraries remain outside these examples.

## Shared component styles

A component `css` body still starts as one literal string. It may reference
shared CSS files with build-time `@import` rules:

```ruby
def css
  %Q{
    @import "./styles/reset.css";
    @import "./styles/controls.css";
    :host { display: block; }
    .btn { padding: 9px 14px; }
  }
end
```

For `lib/MyCounter.rb`, place these fragments in `lib/styles/`. A component in
`lib/nested/` would import `../styles/reset.css`. The build stages `lib/`,
`public/`, and `icons/`; project-root `styles/` is not a supported source root.
Imports resolve relative to the component file, recursively, depth-first in
source order. `@import` rules must come before local CSS. The component's own
rules are applied last, so a local override wins. A shared fragment is emitted
once by stable content identity even when several components import it; the
manifest records each fragment's stable identity and file location, and each
component descriptor lists its ordered `style_resources`. The loader fetches a
shared fragment only when a component that owns it first mounts.

The compiler rejects missing fragments, import cycles, unclosed blocks,
unclosed strings or comments, invalid import syntax, and `#{...}`
interpolation with the component or fragment path and line. Source imports are
resolved at build time; emitted shared CSS files are fetched lazily at runtime.
Shadow roots use constructable stylesheets when
available and an ordered `<style>` fallback otherwise. CSS custom properties
still inherit from the document into both paths.

## Public assets

`public/` is copied as `public/` in the output, not flattened into its root.
For a root-served bundle, `public/logo.svg` is served at `/public/logo.svg`.
Use paths appropriate to your deployment prefix for ordinary image/document
URLs; the loader's manifest-relative resolution applies to framework resources,
not arbitrary HTML URLs. The [asset probe](e2e/fixtures/ui_contracts/probes/12-assets-css)
and [asset-path tests](e2e/tests/gvm_asset_paths.spec.ts) exercise both contracts.

## Icons

Put only the SVG assets the app may use in an `icons/` directory at the project
root. No Lucide/Feather catalog is bundled implicitly. Each file is a normal
SVG with `id="mochi-icon"`. Render it from Ruby:

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

Icon URLs come from the manifest's `resources` entries. The loader resolves
each selected icon file relative to the manifest URL, just as it does for
component descriptors, bytecode, styles, and adapters. Serve the bundle
together under one URL prefix, or place its files in a subdirectory and point
`data-mochi-manifest` at that manifest. Automatic boot finds the default
manifest beside the loader script; an explicit manifest path resolves relative
to that script. This works on deep routes and does not require a `<base>` tag;
existing deliberate base tags remain in effect for
ordinary document links. Route links should use app-appropriate paths. Static
hosts must rewrite deep page requests to the app entry page; resolving asset
URLs does not configure that server behavior.

## Trusted markup

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

Trusted markup is inserted at the authored text position without an implicit
element wrapper. Its nodes can be direct flex/grid children and match direct
child selectors. Write an enclosing element explicitly when it needs its own
styles, attributes, or layout box. When a raw value changes, Mochi replaces
only that value's owned node range; neighboring text, inputs, and components
keep their identity. Raw strings are not parsed again as Mochi templates, so
placeholders or event syntax inside them do not become Ruby bindings. Browser
custom elements in trusted markup connect and disconnect with their inserted
nodes; their tags are not dependency-discovered from a runtime string.

## List rows

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

Rows can own typed child components directly. Keep the key on the row, and pass
Ruby values through declared attributes:

```ruby
class EventRow
  @tag_name = "event-row"
  prop :id, String, required: true
  prop :label, String, required: true
  @expanded

  def initialize
    @expanded = false
  end

  def toggle
    @expanded = !@expanded
  end

  def html
    %Q{
      <article data-id="{@id}">
        <button onclick="{toggle}">{@label}</button>
        {if @expanded}<p>Details</p>{end}
      </article>
    }
  end
end

def html
  %Q{
    {each @events as event, key: event["id"]}
      <event-row id="{event["id"]}" label="{event["label"]}"></event-row>
    {end}
  }
end
```

When migrating child markup assembled from strings or `Mochi.raw` to pass row
values, declare typed child props and write the child tag in the row template.
Keyed rows then retain the child instance and its local state while they move.

## Attributes and form state

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

## Live component attributes

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

## Declared typed props

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

## Numbers

Ruby `Integer` is a checked signed 64-bit value. The VM keeps values that fit
in 32 bits as immediates and boxes wider integers without changing their
observable range. Ruby `Float` is a binary64 value, including `Infinity` and
`NaN` where an operation produces them. Integer division stays integer
division: `1 / 2` is `0`, while `1.0 / 2` is `0.5`. Mixed comparisons and
arithmetic promote the integer operand to `Float`.

Arrays support `sum`, `min`, and `max`, including block forms, through a small
optional Ruby package. Apps that do not call these methods do not load it. See
the [supported Ruby surface](references/RUBY_SURFACE.md#array-aggregation) for
comparison rules and VM limits.

Checked integer overflow, integer division by zero, and unsupported numeric
operations stop the entry with a `mochi:error` instead of wrapping or
truncating. The error names `integer overflow`, `division by zero`, or
`type mismatch` and includes the Ruby method's source location. Floating-point
division by zero follows IEEE 754 and produces `Infinity` or `NaN`, matching
Ruby.

`Integer` and `Float` support `round`, `floor`, and `ceil` with optional decimal
precision from -18 through 18. `round` accepts `half: :up` (default),
`half: :down`, or `half: :even`. Positive precision on a Float returns Float;
zero or negative precision returns Integer. Integer precision at zero or above
keeps the Integer unchanged. Float rounding stays in binary64 and is not an
exact decimal or money operation. Unsupported precision and rounding modes
raise a source-located VM error; non-finite Float conversion at zero or negative
precision raises a Float-domain error, and results outside the signed 64-bit
range raise integer overflow. See the [supported Ruby surface](references/RUBY_SURFACE.md#numeric-rounding)
for exact overloads and examples.

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

## Money helpers

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

Numerators, denominators, minor-unit amounts, and ledger fields must be Ruby
integers. Floats and strings are rejected before arithmetic, so they cannot
create an inexact ledger. Keep a ledger's `:numerator` and `:denominator`
integer-valued if you edit its ordinary Hash fields directly. An operation
that fails while reducing a result leaves its input ledger unchanged.

### Exact money to currency labels

Accumulate exact minor units first, choose one named rounding mode at the
display boundary, then pass the integer minor-unit result and explicit scale to
`MochiFormat.currency`:

```ruby
def currency_label(ledger)
  cents = MochiMoney.round_half_up(ledger)
  MochiFormat.currency(cents, "USD", "en-US", 2)
end

charge = MochiMoney.amount(56_951, 1_000) # 56.951 cents, exact
currency_label(charge) # "$0.57"

adjusted = MochiMoney.ledger
MochiMoney.merge(adjusted, charge)
MochiMoney.add_ratio(adjusted, -951, 1_000) # negative adjustment
currency_label(adjusted) # "$0.56"

line_a = MochiMoney.amount(2, 5)
line_b = MochiMoney.amount(2, 5)
line_c = MochiMoney.amount(2, 5)
total = MochiMoney.ledger
MochiMoney.merge(total, line_a)
MochiMoney.merge(total, line_b)
MochiMoney.merge(total, line_c)

currency_label(line_a) # "$0.00"
currency_label(line_b) # "$0.00"
currency_label(line_c) # "$0.00"
currency_label(total)  # "$0.01"
```

The labels for individual lines are presentation only; never add them back
into the ledger. The exact total is `6/5` cents even though each line displays
as zero cents. Ordinary `Float#round` follows Ruby's floating-point rules and
does not provide exact money accumulation. Keep money in `MochiMoney` ledgers
until display, then use the resulting integer with the requested currency,
locale, and scale. Both helpers load on demand when the component's Ruby code
uses them; application code needs no JavaScript or adapter script tag.

The helper performs no currency symbols, grouping, decimal separators, or
locale lookup. Format the integer returned by a `round_*` method in your
component. Applications that do not use `MochiMoney` pay no bytes for it; the
compiler attaches the helper package to the components that depend on it.

## Number and date formatting

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

`currency` takes an exact integer number of minor units and divides by
`10^scale` at the display boundary. Floats (including `1.0`) and numeric
strings are rejected with a `mochi:error` identifying the integer-minor-unit
requirement. Scale must be an integer from 0 through 20. The absolute amount
limit is 1,000,000,000,000,000 minor units; larger values report an error
instead of silently returning an imprecise JavaScript number. Use the
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

## Host capability adapters

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

## Synchronous event modifiers and focus

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
  event[:target_dataset]            # data-* on the browser event target
  event[:current_target_dataset]    # data-* on the bound handler element
  event[:composed_path].map { |node| node[:tag] }
end
```

The payload includes `target`, `current_target`, `target_ref`, `target_tag`,
`current_target_ref`, `current_target_tag`, `current_target_id`, and
`composed_path`. Path entries contain only `tag`, `id`, `ref`, and `component`
labels. `dataset` and `target_dataset` contain the same target data;
`current_target_dataset` contains data from the element bearing the handler.
For a row handler, use `event["current_target_dataset"]["id"]` to select the row
even when a nested label receives the click. These are snapshots of string
values with DOM dataset key casing (`data-row-id` becomes `rowId`); internal
`mochi*` keys are filtered. No nearest-ancestor dataset search occurs.

Across a nested shadow boundary, the target follows browser retargeting and
may be the child host. The current target is still the bound handler element,
not the delegated shadow-root listener. `composed_path` remains label-only.
Typed child events retain exactly their declared payload; they receive none
of this native DOM metadata. Dataset copies count toward the existing event
argument byte limit; see [capacity failures](references/CAPACITY_CONTRACT.md).

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

## Scoped child events

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

Global Ruby events require explicit subscriptions. A component registers an
event name and receiver method, then publishes the event with a Hash payload:

```ruby
def mounted
  Mochi.subscribe("profile_opened", :receive_profile)
end

def open_profile
  Mochi.emit("profile_opened", id: "tr_1", active: false)
end

def stop_listening
  Mochi.unsubscribe("profile_opened", :receive_profile)
end

def receive_profile(payload)
  @profile_id = payload[:id]
end
```

Duplicate registration for the same component, event, and receiver is
idempotent. The loader also removes subscriptions when their component is
disposed. A method receives nothing just because its name matches a published
event; it runs only when registered. `Mochi.emit` no longer broadcasts
`mochi:action` DOM events or supports `target:` filtering. See
[API migrations](references/API_MIGRATIONS.md#global-events) for migration.

Subscriptions made in `initialize` or `mounted` belong to that mount. They
receive publications only once the component is ready; earlier publications
are skipped without removing the subscription and are not replayed. A failed
mount removes its registrations. Within one Ruby handler, subscribe, emit, and
unsubscribe take effect in statement order; explicit self-subscription works
the same way as subscribing another instance.

Payloads are Hashes with String/Symbol keys and nested arrays, hashes, strings,
symbols, finite numbers, booleans, or nil. Signed 64-bit integers remain exact.
Objects, non-finite numbers, cycles, excessive nesting (over 16 levels), and
payloads exceeding the compiled transport bound fail with Ruby source context
before delivery. A failed handler's pending publications are discarded.

## Component lifecycle

Moving a connected component between positions in the same turn preserves its Ruby instance, state, timers, and event handlers; `unmounted` and `mounted` do not run again. If the element stays disconnected through that turn, the loader disposes it once and runs `unmounted`. Reinserting it afterwards performs a fresh mount from `initialize`, rebuilding props, bindings, and handlers.

## Routing and history

Routing is opt-in. An app that never mentions `AppRouter` does not ship route
matching or parameter parsing bytecode, and its components do not subscribe to
route changes.

Declare the route table in the component that owns screen selection:

```ruby
@router = AppRouter.build
AppRouter.on(@router, "/", "home")
AppRouter.on(@router, "/logs", "logs")
AppRouter.on(@router, "/logs/:log_id", "logs")
AppRouter.not_found(@router, "not_found")

apply_route(AppRouter.resolve(@router))
Mochi.route_subscribe
```

`Mochi.route_subscribe` registers the current component for structured route
updates. On navigation, back, forward, or direct entry, the component's
`on_route(payload)` receives one Ruby Hash:

```ruby
{
  "path" => "/logs/hello world",
  "segments" => ["logs", "hello world"],
  "query" => { "level" => "warn" },
  "search" => "level=warn",
  "hash" => false,
  "href" => "http://localhost/logs/hello%20world?level=warn"
}
```

Paths and query values are decoded before they reach Ruby. `AppRouter.resolve`
adds the matched screen and named parameters:

```ruby
route = AppRouter.resolve(@router, payload)
route["screen"]      # => "logs"
route["params"]      # => { "log_id" => "hello world" }
route["query"]       # => { "level" => "warn" }
route["matched"]     # => true
route["not_found"]   # => false
```

All values are Strings, or `nil` when absent. A route host can pass typed props
to the screen it owns when a screen needs a declared input before `initialize`.

`Mochi.navigate(path)` appends a history entry. `Mochi.replace_route(path)`
rewrites the current entry; `AppRouter.push` and `AppRouter.replace` are
convenience wrappers. The loader owns one URL model per page: a hash route owns
the URL when it is present on entry, otherwise the pathname and query string
do. `/index.html` is treated as `/`. Initial route state is installed before the
entry component mounts, browser `popstate` and `hashchange` notify route
subscribers, and navigation uses `history.pushState`/`replaceState`.

Only components that call `Mochi.route_subscribe` receive route payloads. Other
components are not asked to coordinate navigation, and an action such as
`goto_screen` is not part of the routing path. Legacy apps with no route
subscribers keep the old `on_route(path_string)` broadcast behavior.

Conditional and list-row child tags load their descriptor and bytecode when the
branch or row first mounts. A route host therefore does not eagerly download
every screen: a direct `/costs` entry loads the shell, its always-rendered
chrome, and the Costs dependency closure. If navigation changes before a
screen's bytecode finishes loading, the loader's mount token drops the
superseded mount.

Static hosts must rewrite extensionless application paths to the entry page.
The GVM loader resolves runtime files from the manifest URL, including on deep
routes; use root-based or deployment-prefix URLs for ordinary document assets
and links. Hash routes need no server rewrite.

## Storage and subscriptions

Storage is a core VM capability. `Mochi.storage_get(key, default)`,
`Mochi.storage_set(key, value)`, and `Mochi.storage_remove(key)` are available
without an optional package; `get_storage`, `set_storage`, and
`remove_storage` are aliases. Values are raw Strings. Numbers and booleans are
converted to text, while Hash, Array, and `nil` become `""`; encode structured
data yourself and validate it when it is read back.

`Mochi.storage_subscribe(key, callback)` registers the current component and
immediately delivers one initial payload:

```ruby
Mochi.storage_subscribe("cowboy_theme", "on_theme")

def on_theme(payload)
  # payload["value"], payload["previous"], payload["source"],
  # payload["ok"], payload["error"]
end
```

`source` is `"initial"`, `"same_tab"`, or `"external"`. Same-tab `storage_set`
and `storage_remove` notify subscribers directly without waiting for a browser
event. Other tabs are observed through the browser `storage` event. Equal
writes produce no notification. Removing a key delivers `value: nil`, and the
loader also clears the VM copy so `Mochi.storage_get` stays synchronized.
Unmounting a component removes all of its storage subscriptions.
A screen hidden with CSS or a conditional style change remains mounted and
subscribed; removing the component from the tree releases its subscription.

The host seeds existing localStorage entries into the VM before component
initialization, so a component can read the current value in `initialize` and
then subscribe for later changes. Initial delivery reads the same source, so
reloads resolve persisted values before dependent bindings render.

Failures keep the previous value and produce one payload with `ok: false` and
`error: "quota"` or `error: "unavailable"`. A quota failure rolls the VM copy
back to the value still in storage. Inaccessible storage reports
`error: "unavailable"` and leaves Ruby to apply its own default. Failures are
also reported through the loader error hook with the `storage` phase.

The optional `MochiStore` battery adds Ruby helpers for defaults, effective
writes, and fallback after an error:

```ruby
store = MochiStore.build("cowboy_theme", "light")
current = MochiStore.value(store)
MochiStore.write(store, "dark")
MochiStore.accept(store, payload)   # apply a subscription payload
MochiStore.error(store)             # "", "quota", or "unavailable"
MochiStore.clear(store)             # remove and return the default
```

It is emitted only when an application mentions `MochiStore`; applications
that call the core builtins directly do not ship it. `MochiStore` does not
define a global state framework and keeps one String value per key.
`MochiStore.write` returns `false` when the requested text already matches the
VM's current value and `true` when it queues a changed write. The browser
persists that command after the Ruby entry returns, so `true` is not a durable
write receipt. Confirm the `storage_subscribe` payload: `ok: true` confirms a
successful change, while `ok: false` carries the still-persisted value and an
`error`. `MochiStore.accept` applies that value and keeps the error visible;
quota and unavailable failures are also sent through `mochi:error` with phase
`storage`. A later successful payload clears the helper error.
`MochiStore.clear` queues a removal and returns the local default; use its
subscription payload to confirm removal or observe failure.

Storage values travel in bounded host commands. The active capacity profile's
`host_emit_envelope_bytes` limits the full command, including JSON escaping and
its envelope; see [capacity limits](docs/fixed-capacities.md) and the
[capacity failure contract](references/CAPACITY_CONTRACT.md). JSON's own
document limit does not mean a document fits in one storage command. Store small
preferences and drafts, not documents. Invalid or unexpected text is not
repaired by the host: validate its shape in Ruby, use an explicit default, and
write corrected text back. The
[storage fixture](e2e/fixtures/feedback_review/lib/StorageRoot.rb) demonstrates
this with a small JSON preference object.
