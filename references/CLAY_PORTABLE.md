# Portable projects

Put `mochi-portable.json` at the project root to build one Mochi screen for
the browser and the experimental macOS host.

```json
{
  "version": 1,
  "root": "record-inspector",
  "app_id": "org.mochi.stations",
  "display_name": "Stations",
  "window": { "inset": 24, "max_width": 520 },
  "fonts": {
    "StationSans": {
      "400": { "file": "public/station-sans.woff2", "license": "public/OFL.txt" },
      "700": { "file": "public/station-sans-bold.woff2", "license": "public/OFL.txt" }
    },
    "StationSymbols": {
      "700": { "file": "public/station-symbols-bold.woff2", "license": "public/OFL.txt" }
    }
  }
}
```

`root` is the component's `@tag_name`. Give `app_id` a stable reverse DNS
identifier and `display_name` the name users should see. Mount the declared
tag in `index.html`. Mochi loads each component's font stylesheet on mount
and the browser downloads the faces needed by its text.

## Window and component layout

Set `window` when the root owns the window surface. Mount that root directly
under `body` in the browser entry. Mochi sets the document margin to zero and
uses a white window background on both hosts. `inset` defaults to zero and
applies to all edges. `max_width` is optional and caps the root's border-box
width. The root stays left-aligned at its inset when the window is wider than
the cap. Both values are whole logical pixels. Without `window`, the web entry
owns its outer layout.

Mochi reads shared CSS depth-first in import order. Local rules follow them.
Only single-class selectors are supported. Rules at equal specificity apply
in stylesheet order even when Ruby returns classes in a different order.
Shared fragments have stable identities and load when a component that uses
them mounts. Styles stay scoped to that component.

Containers stack vertically by default. `display: flex` defaults to a row.
Use `flex-direction` to set either axis explicitly. Automatic width uses the
available space in a column and fits the content in a row. A fixed `width` or
`height` includes padding. Uniform `padding` and `gap` use whole logical
pixels. Text inherits its color, family, size, weight and line height, including
inside buttons. Buttons start with zero border and padding and left-aligned text.

Use `@container (max-width: 315px)` around single-class rules that change
`flex-direction`. The threshold is inclusive and measures the root's
logical width after the window inset and width cap. Both hosts reevaluate the
rule when the root resizes.

The portable profile supports one vertical scroll region. Give a column
`div` an explicit `height` or `max-height` and `overflow-y: auto`. Rows retain
their natural height and keep their keys as the viewport moves. Keyboard focus
reveals the focused row. Updates preserve the scroll offset and clamp it when
content shrinks. The scroll region clips paint and pointer hits at its viewport.
Use `tabindex="0"` on row buttons to put them in the browser's keyboard order.

The native Clay frame accepts up to 510 explicit boxes and nonempty text
leaves, including Mochi's app wrapper, and up to 65,536 UTF-8 text bytes.
An over-limit frame names the component and limit. A fresh mount can render
after a capacity failure.

Layout, hit testing, and accessibility use logical bounds. AppKit maps
each paint edge to the active drawing target's device coordinates and rounds
each edge independently to the nearest device pixel. Layout keeps fractional
widths, including widths measured from text.

## Local fonts

Use static WOFF2, OTF or TTF files under `public/` and declare each face's
weight from 100 to 900 in steps of 100. A string path is shorthand for weight
400 and picks up an adjacent `OFL.txt` when present. The weighted form can
name a local license file explicitly. The macOS toolchain includes a WOFF2
decoder. For a checkout-backed build, install `woff2_decompress` or set
`MOCHI_WOFF2_DECOMPRESS`. Mochi packages the faces that can reach a text leaf
and their licenses through the font resource graph.

List local faces in order, for example
`font-family: StationSans, StationSymbols, sans-serif;`. Mochi resolves the
exact declared weight and assigns glyphs to the first matching face.
If the local stack has no face for the requested weight, both builds report
the authored CSS location. The optional generic tail uses the platform
default for glyphs outside the local stack's coverage. An empty `fonts`
object supports a generic-only screen.

The inspector verifies printable ASCII, precomposed é, and Ω from its
bundled symbol face. Regular and bold text share explicit line heights
and the AppKit baseline is rounded to the nearest logical pixel.
The parity fixture exercises 1× and 2× captures around its wrap boundary.

```sh
mochi -i . -o build/web
mochi --target=desktop -i . -o build/mac
mochi test -i .
mochi test --target=desktop -i .
```

Both builds validate the declared root, including inactive branches, required
Ruby packages and shared CSS imports. Diagnostics name the component and the
Ruby or stylesheet line. Both builds compile the root's package closure.
Projects without the declaration use the ordinary DOM build.

Version 1 covers the station inspector's `div`, `span` and `button` templates,
local Ruby state, conditionals, explicitly keyed flat rows, click handlers
and single-class flex styles.

## Child components

Mount an empty child tag in a component, conditional branch, or keyed row. Declare its
inputs with `prop` and connect its declared events with
`on:confirm="{confirm_station($event)}"`. Use dashed attribute names for
declared props with underscores. Each mounted child owns its own Ruby
instance and styles. Constructor inputs are independent snapshots, and a
parent patch installs all changed inputs before the child's bindings run.
The child can emit the same typed payload to its owning parent on either host.

A bad mount leaves the other controls active. A rejected input update keeps
the previous child inputs. An invalid event reports its declaration and
skips the parent handler. Closing a branch disposes its child. Reopening
creates a fresh instance with the current parent inputs.

A keyed row retains its mounted children, local state and controls when it
moves. Key identity includes the parent mount, the list site and the key's
type. Duplicate keys report the template location and leave the previous list
in place. A removed row unmounts once. Tab follows the current row order. If
the focused row disappears, focus moves to the first focusable control in a
surviving row at or after the old position, then tries preceding rows. If no
surviving row has a focusable control, focus leaves the list.
See the [station inspector](../e2e/fixtures/clay_inspector) for a working
project and its shared Ruby scenario.

## Text fields and checkboxes

Use a text `input` with `bind:value` and an optional `oninput` handler.
Use `type="checkbox"` with `bind:checked` and an optional `onchange`
handler. Associate a text-only `label` using `for` and the input's
`id`, or supply `aria-label`. Bind `disabled` to a Ruby Boolean to
control editing and keyboard activation.

Ordinary text edits and paste commit on input. IME marks remain in the host
editor until the composition commits. The Ruby handler runs once with the
new value already installed. Checkbox activation installs the checked
Boolean before its handler runs. Unrelated patches preserve editor identity,
focus, selection and marked text. AppKit uses the native field editor and
switch control, with standard Edit menu shortcuts. The web editing adapter
loads with the first portable component that uses these bindings.

The [standalone station editor](../e2e/fixtures/clay_editor) runs the same
Ruby edit scenario on both targets.

## App storage

The portable profile supports `Mochi.storage_get`, `storage_set`,
`storage_remove`, their existing aliases, and `storage_subscribe`.
`MochiStore` uses the same operations. The desktop target loads confirmed
values before Ruby initialization. Empty strings stay present, and removing
a key restores the caller's default.

macOS stores data under `~/Library/Application Support/Mochi/Storage/`.
The SQLite filename is a SHA-256 hash of the declared `app_id`. App code
uses its storage receipt to confirm the local transaction. A failed write
reports `quota` or `unavailable` and restores the last confirmed value
in the VM. The native quota keeps a key and two copies of any stored value
within the VM's callback argument limit, including JSON escaping. SQLite
full and size-limit errors also report `quota`. [SQLite synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous)

Same-app mounts receive the existing `same_tab` source for effective local
changes. Equal writes produce no receipt. Unmounting releases the subscription.
Desktop reads observe external changes at relaunch. A write compares the
current durable value for its key so concurrent launches can update different
keys independently. Browser storage continues to report external tab changes
under the existing web contract.

Each `mochi test --target=desktop` invocation uses a temporary store. Use
`MOCHI_DESKTOP_STORAGE_DIR` with an isolated directory for tests that
intentionally share storage across processes. See the
[station storage fixture](../e2e/fixtures/clay_storage).

## Installed macOS toolchain

Produce both archives from a built Mochi checkout with `task toolchain:package`.
This uses Xcode command line tools, `woff2_decompress`, Goose, and a matching
`mochi-gvm` checkout with current web and standalone Goose artifacts. Set
`MOCHI_GVM_DIR` when that checkout is outside the default sibling directory.
Run packaging on each target architecture, `arm64` or `x86_64`, with system
and library deployment targets appropriate for the intended Macs. For the
core archive alone, run `ruby scripts/package_toolchain.rb` after `task build`.

Install from the directory containing the two archives. Choose a prefix on
your PATH or invoke the installed launcher by its full path.

```sh
arch=$(uname -m)
mkdir -p mochi-installer
tar -xzf "mochi-macos-$arch.tar.gz" -C mochi-installer
ruby mochi-installer/install.rb --prefix "$HOME/Tools/mochi" \
  --desktop "mochi-desktop-macos-$arch.tar.gz"
```

Omit `--desktop` for a web-only install. From the same installer, use `update`
with the new matching archive pair or `remove` with the existing prefix.
The installed desktop CLI uses a prelinked AppKit and Clay executable and
uses a separate prelinked runner for Ruby tests. The app checkout only needs
its project sources and assets. App packaging uses system Ruby and `plutil`.

The installer records absolute resource paths and validates the matching CPU,
bundle and scene schemas, native ABI, and capacity fingerprint. Set
`MOCHI_DESKTOP_TOOLCHAIN` to an extracted matching desktop archive to
override the recorded package. An invalid explicit path fails the build.
`MOCHI_WOFF2_DECOMPRESS` also takes precedence over the recorded decoder.

`mochi --target=desktop -i . -o build/mac` uses the application's
`display_name` for the bundle filename and its `app_id` for the bundle
identifier. A successful build can replace a previous Mochi product with
the same filename and identifier. You can move and launch the finished
`.app` offline. Release signing and notarization are separate steps.

## Checkout-backed native build

`task desktop:demo` links the AppKit host using the matching GVM source
checkout and writes `build/desktop-mvp/Stations.app`. Hosted macOS CI uses
the full upstream commit SHA in `MOCHI_NATIVE_GVM_REVISION`. The host
requires native ABI v3 and validates the scene's capacity fingerprint before
loading Ruby.

The ABI uses a single VM with serialized calls and loads identical Ruby
packages once per process. Each successful mount owns
its own instance handle until unmount. Dispatch and patch reads run on the
AppKit thread. Native patch and error buffers are borrowed, and AppKit
decodes and copies a complete patch batch before publishing any values.
