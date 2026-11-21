<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/yampug/mochi/blob/main/github/assets/banner_dark.png?raw=true">
    <source media="(prefers-color-scheme: light)" srcset="https://github.com/yampug/mochi/blob/main/github/assets/banner_light.png?raw=true">
    <img alt="Mochi Banner" src="https://github.com/yampug/mochi/blob/main/github/assets/banner_light.png?raw=true">
  </picture>
</p>

[![License](https://img.shields.io/badge/license-MIT-green?labelColor=gray)](LICENSE.md)

## What is Mochi?

Mochi brings Ruby to the browser. Write components, templates, interactions,
and behavior tests in Ruby, with optional Sorbet typechecking. Mochi compiles
Ruby to bytecode that runs in its WebAssembly VM and renders through Web
Components. No application JavaScript required.

Optional capabilities load when needed. The goal: everything a Ruby developer
needs to build a browser application, with only the bytes that application needs.

Mochi is under active development; APIs and supported Ruby features are evolving.

## Getting Started

The current setup uses a source checkout. You need Crystal, Task, Ruby, Node.js,
the [external libraries](docs/BUILD_INSTRUCTIONS_EXT_LIBS.md), and compatible
GVM runtime and `mrbc` artifacts. See the [build and installation guide](AGENTS.md#building-mochi-from-source)
for details.

```sh
git clone https://github.com/yampug/mochi
cd mochi
task install
# Add the printed ~/.local/bin path to PATH if needed.

# Install browser test dependencies once, from the Mochi checkout.
(cd e2e && npm ci && npx playwright install chromium firefox webkit)

# Create your app outside the framework checkout.
cd ..
mochi --initialize=hello_mochi
cd hello_mochi
mochi -i . -o ./build
mochi lint -i .
mochi test -i .
mochi dev --config=./dev_server_config.json --root=./
```

Open <http://127.0.0.1:27490>. The generated project includes components in
`lib/`, Ruby behavior tests in `test/`, an HTML entry page, and a
`.mochi-lint.yml` policy with `task lint` and `task check` commands.

`mochi lint` checks the Ruby sources without building or running the
application. Compilation and `mochi dev` do not run it automatically. Run
`task lint` or `mochi lint -i .` explicitly, and let `task check` or CI enforce
it. Every enabled warning or error is blocking, and the command exits nonzero
for either. See the [lint contract](references/LINT_CONTRACT.md) for
configuration, exit codes, rule defaults, and suppression forms.

`mochi test` runs in Chromium, Firefox, and WebKit. Use
`mochi test -i . --browsers=chromium` for a single engine, or add `--typecheck`
to the build command to check your Ruby with Sorbet.

### Build the Stations example for web and macOS

With the [installed macOS toolchain](references/CLAY_PORTABLE.md#installed-macos-toolchain),
run these commands from the Mochi checkout. Both outputs use the same Ruby
components and templates.

```sh
mochi -i e2e/fixtures/clay_inspector -o build/stations-web
mochi --target=desktop -i e2e/fixtures/clay_inspector -o build/stations-mac
```

Serve the web directory with a static server or launch
`build/stations-mac/Stations.app` on the Mac. The
[portable project guide](references/CLAY_PORTABLE.md) covers shared tests,
supported features, and distribution.

## Example Component

A component declares its HTML tag, keeps state in Ruby instance variables,
and connects buttons to Ruby methods:

```ruby
class MyCounter
  @tag_name = "my-counter"
  @count

  def initialize
    @count = 0
  end

  def increment
    @count = @count + 1
  end

  def html
    %Q{
      <h1>Count: {@count}</h1>
      <button onclick="{increment}">Increment</button>
    }
  end
end
```

Save it as `lib/MyCounter.rb` and use `<my-counter></my-counter>` in your
page. The generated starter already includes a counter and a test to try.

## Learn More

- [Ruby task guide](references/RUBY_TASK_GUIDE.md): recipes for timers, preferences, downloads, events, datasets, shortcuts, and screen lifetimes.
- [Lint contract](references/LINT_CONTRACT.md): CLI, configuration, exit codes, rule defaults, and inline suppressions.
- [Ruby examples](e2e/fixtures/ui_contracts/README.md): a record inspector, SVG graph editor, and nested form.
- [Supported Ruby](references/RUBY_SURFACE.md): available APIs and current limits.
- [Project guide](AGENTS.md): styling, props, events, routing, capabilities, and contributor commands.
- [Payload budgets](references/PAYLOAD_BUDGETS.md): measured bundle sizes and loading behavior.

## License

[MIT](LICENSE.md)
