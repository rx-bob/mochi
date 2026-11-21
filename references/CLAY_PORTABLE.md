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

## Static web deployment

Keep the loader URL relative in the entry page and mount the root component
in the body.

```html
<script src="mochi-loader.js" defer></script>
<record-inspector></record-inspector>
```

Build the station inspector into a nested directory and serve its parent.
Open `http://localhost:8080/deployments/tenant/stations/`, including the
trailing slash so the browser resolves the loader URL inside that directory.

```sh
mochi -i e2e/fixtures/clay_inspector -o build/web/deployments/tenant/stations
python3 -m http.server 8080 --directory build/web
```

Deploy the entire output directory together. The loader finds the manifest
beside itself, the manifest locates descriptors, bytecode and styles, and
generated font stylesheets locate their font files relative to themselves.
The root and station rows load on entry. Opening Details fetches its descriptor,
bytecode and scoped stylesheet and reuses the loaded regular face. Chromium,
Firefox and WebKit verify these requests and the rendered controls.

For an app with deep routes, configure the host to rewrite navigation within
the prefix to its entry page. Set the loader URL to its deployment path, such
as `/deployments/tenant/stations/mochi-loader.js`, or set a document base at the
prefix. Ordinary authored asset URLs follow browser URL rules. Serve framework
and font files directly, with `application/wasm` for WASM and `font/woff2` for
WOFF2.

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

| Feature | Browser and AppKit |
| --- | --- |
| Layout and styling | `div` and `span`, single-class flex styles, one vertical scroll region, and a root container-width rule |
| Controls | Text labels, buttons, text inputs, and checkboxes with accessible names, disabled state, and keyboard focus |
| Composition | Ruby state, conditionals, keyed flat rows, typed child props, and scoped child events |
| Editing and persistence | Live field bindings, focus refs, polite status messages, and confirmed local storage writes |
| Fonts | Declared static faces and a generic platform fallback |

The first profile covers the features in this table. Rich text, arbitrary
DOM access, SVG and general CSS are outside it. For a rejected feature, read
the component and Ruby, template, or stylesheet location in the compiler
message. Check inactive template branches, stylesheet imports and the
declared package closure as well as the visible screen.

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
control editing and keyboard activation on inputs and buttons. Use
`tabindex="0"` on controls that must participate in the keyboard order
across browsers.

Ordinary text edits and paste commit on input. IME marks remain in the host
editor until the composition commits. The Ruby handler runs once with the
new value already installed. Checkbox activation installs the checked
Boolean before its handler runs. Unrelated patches preserve editor identity,
focus, selection and marked text. AppKit uses the native field editor and
switch control, with standard Edit menu shortcuts. The web editing adapter
loads with the first portable component that uses these bindings.

The [standalone station editor](../e2e/fixtures/clay_editor) runs the same
Ruby edit scenario on both targets.

Give a button or input a static `ref` to focus it with `Mochi.focus(:name)`.
The ref belongs to the component that declares it. The host applies the focus
request after rendering, so it can reach a newly enabled control. Keep an
`aria-live="polite"` text span mounted and change its text to announce
validation or storage errors. AppKit posts the corresponding accessibility
announcement when the text changes.

## Editing a station

The inspector opens a draft for the selected station and focuses **Station
name**. **Save station** stays disabled until a field changes. A blank or
whitespace-only name shows **Enter a station name.** and returns focus to
the name field. The editor stores the name and **Open to public** checkbox in
one JSON value under the station ID. Only a confirmed save updates the row and
returns focus to **Edit station**. A failed write shows **Could not save
station. Try again.** and keeps the current controls, draft and focus.
**Cancel** discards the draft and returns focus to the same button.

Run the authored scenario from the repository root. Each invocation uses
isolated storage by default. An archive-installed CLI needs the Playwright
dependencies from the checkout for browser tests.

```sh
MOCHI_E2E_NODE_MODULES="$PWD/e2e/node_modules" \
  mochi test -i e2e/fixtures/clay_inspector --test-file=editor_test.rb --browsers=all
mochi test --target=desktop -i e2e/fixtures/clay_inspector --test-file=editor_test.rb
task desktop:parity
```

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
`.app` offline.

## Distributing Stations

`task stations:candidate` packages the toolchains and installs them under a
temporary prefix. It builds the static directory and `Stations.app` from
one copy of the project, then unpacks the resulting ZIPs into a separate
directory. The shared [Ruby editor scenario](../e2e/fixtures/clay_inspector/test/editor_test.rb)
runs against the web entry under `/deployments/tenant/stations/` in Chromium,
Firefox and WebKit. The AppKit runner uses the extracted app's resources and
a fresh storage directory. The extracted executable also mounts its own
resources with networking denied. The macOS CI job stages the verified
candidate ZIPs and matching toolchain archives as build artifacts.

The local candidate was verified on **Apple silicon (arm64), macOS 26.6.2**.
Its Mach-O deployment minimum is **macOS 15.5**. The candidate log reports
both versions. Use `xcrun vtool -show-build Stations.app/Contents/MacOS/Mochi`
to confirm the deployment minimum for the app you plan to ship. Claim other
versions or architectures after the same artifact checks and recipient test
pass there.

The bundled regular and bold faces cover printable ASCII and precomposed
é. The bold symbol face covers Ω. Other glyphs use the host fallback.
The Clay frame allows 510 boxes and nonempty text leaves, including the
app wrapper, and 65,536 UTF-8 text bytes. See the
[fixed VM capacities](../docs/fixed-capacities.md) and [app storage](#app-storage)
for runtime and write limits. The [parity report](../e2e/fixtures/clay_inspector/PARITY.md)
records the widths and scales checked. Measured box edges and line metrics
agree within one logical point. The native field bezel, checkbox glyph,
focus rings, window chrome and system popovers keep host appearance.

### Sign and verify the recipient ZIP

On the signing Mac, install a Developer ID Application certificate in the
Keychain and create a `notarytool` profile interactively. Use Xcode's
`notarytool` and `stapler` tools. Keep the private key and Apple credentials
in the Keychain.

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials mochi-release
MOCHI_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  MOCHI_NOTARY_PROFILE=mochi-release \
  ruby runtime/desktop/distribute.rb package \
  build/stations-mac/Stations.app build/stations-macos-arm64.zip
ruby runtime/desktop/distribute.rb verify build/stations-macos-arm64.zip
```

The packager signs a staged copy with hardened runtime and a secure
timestamp, submits it to Apple, staples the accepted ticket to the app
and creates the recipient ZIP. The verifier checks the extracted app's
Developer ID signature, ticket and Gatekeeper assessment. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

Run the same release contract on the final ZIP pair with the matching
toolchain archives from the same revision.

```sh
ruby scripts/stations_release.rb verify build/toolchains \
  /path/to/stations-web.zip build/stations-macos-arm64.zip
```

On a separate clean Mac for each supported architecture, download the final
ZIP through a browser to retain quarantine and extract it with Finder.
Disconnect the network before first launch. Open **Stations**, select **Café**,
click **Edit station**, and save **Café North** with **Open to public** checked.
Quit and reopen the app, then reopen the editor and confirm both values.
Record the macOS version, architecture and ZIP SHA-256 with the result.

When publication is authorized, attach the verified web and signed Mac ZIPs,
the matching toolchain archives and this guide to the project's tagged GitHub
release. Use the app ZIP that passed the recipient check. For static hosting,
deploy the extracted `stations/` directory under the chosen prefix. The
[payload audit](PAYLOAD_BUDGETS.md#shipped-loader-formatting) verifies the
shared web runtime and existing size ceilings.

## Checkout-backed native build

`task desktop:demo` links the AppKit host using the matching GVM source
checkout and writes `build/desktop-mvp/Stations.app`. The macOS CI workflow
pins the matching companion source revision by full commit SHA. The host
requires native ABI v3 and validates the scene's capacity fingerprint before
loading Ruby.

The ABI uses a single VM with serialized calls and loads identical Ruby
packages once per process. Each successful mount owns
its own instance handle until unmount. Dispatch and patch reads run on the
AppKit thread. Native patch and error buffers are borrowed, and AppKit
decodes and copies a complete patch batch before publishing any values.
