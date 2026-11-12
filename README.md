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
current attribute into the child instance through the set-ivar ABI; a later
change to the attribute, including one produced by a parent binding, updates
the mounted child in place. The child keeps its Ruby instance, bindings, and
DOM nodes.

```ruby
def html
  %Q{<child-badge label="{@label}"></child-badge>}
end
```

The setter reports `0` for success and `-1` for failure. A failure is reported
as a `mochi:error` with `phase: "attribute"` plus the failing `attribute` and
`property`, instead of being treated as a successful no-op. Re-writing the
current value is a successful no-op and produces no patch, so an observer that
echoes the attribute cannot start an update loop. Removing the attribute writes
an empty string; it does not re-run the child's `initialize`, so an explicit
Ruby default applies only to a fresh mount.

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
