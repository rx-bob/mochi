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

### Trusted markup

Template values are text by default, whether they stand alone, sit inside a
sentence, or come from an `each` row. A string containing `<b>`, quotes, or an
event-handler attribute is displayed literally.

Use `Mochi.raw(expression)` when an app-authored value intentionally contains
markup, such as an inline SVG icon:

```ruby
def html
  %Q{
    <span class="icon">{Mochi.raw(IconLibrary.svg("settings"))}</span>
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

Supported types are `String`, `Integer`, `Boolean`, `Array`, and `Hash`. A
declaration can be `required: true` or provide `default:`, but not both. Default
expressions may be literals or constants. The compiler rejects unknown types,
duplicate names, an unknown option, and a default whose literal type does not
match the declaration.

The loader resolves declared props before it creates the VM instance. A missing
required input or a value that does not match its type aborts the mount with a
`mochi:error` naming the prop, the component, and the declaration's source
location. Nothing is partially mounted.

HTML text maps to Ruby as follows:

| Declared type | Attribute text | Ruby value |
| --- | --- | --- |
| `String` | any text | that string, including `""` |
| `Integer` | `-?[0-9]+` inside the VM's 32-bit range | `Integer` |
| `Boolean` | `true`, `false`, or `""` (HTML presence) | `true` or `false` |
| `Array` | JSON array text | a new Ruby `Array` |
| `Hash` | JSON object text | a new Ruby `Hash` |

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

Payload fields use `lower_snake_case` and support `String`, `Integer`,
`Boolean`, `Array`, and `Hash`. Integer fields use the VM's 32-bit range. The
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

The Crystal compiler emits a `mochi-gvm` bundle: `mochi-gvm.wasm`, `mochi-gvm.js`, `mochi-loader.js`, `mochi-manifest.json`, and one `.chi` file per component. It does not generate component-specific JavaScript.

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
| `task check` | Run specs, GVM tests, and the GVM end-to-end test |

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

The output is a ready-to-serve GVM bundle. Load `mochi-loader.js` from your entry page; the loader fetches the manifest, WASM, and component `.chi` files.



## License

[MIT](LICENSE.md)
