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

Layout, hit testing, and accessibility use logical bounds. AppKit maps
each paint edge to the active drawing target's device coordinates and rounds
each edge independently to the nearest device pixel. Layout keeps fractional
widths, including widths measured from text.

## Local fonts

Use static WOFF2, OTF or TTF files under `public/` and declare each face's
weight from 100 to 900 in steps of 100. A string path is shorthand for weight
400 and picks up an adjacent `OFL.txt` when present. The weighted form can
name a local license file explicitly. Install `woff2_decompress` to build
projects that use WOFF2. Mochi packages the faces that can reach a text
leaf and their licenses through the font resource graph.

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

Mount an empty child tag in a component or conditional branch. Declare its
inputs with `prop` and connect its declared events with
`on:confirm="{confirm_station($event)}"`. Use dashed attribute names for
declared props with underscores. Each mounted child owns its own Ruby
instance and styles. Constructor inputs are independent snapshots, and a
parent patch installs all changed inputs before the child's bindings run.
The child can emit the same typed payload to its owning parent on either host.

A bad mount leaves the other controls active. A rejected input update keeps
the previous child inputs. An invalid event reports its declaration and
skips the parent handler. Closing a branch disposes its child. Reopening
creates a fresh instance with the current parent inputs. The portable
profile currently supports child tags outside keyed rows.
See the [station inspector](../e2e/fixtures/clay_inspector) for a working
project and its shared Ruby scenario.

## Native development build

The AppKit host links a matching `mochi-gvm` source checkout. Build its
standalone Goose artifacts first and point `MOCHI_GVM_DIR` to that checkout
when it is outside the default sibling directory. The host requires native
ABI v2 and validates the scene's capacity fingerprint before loading Ruby.
Hosted macOS CI uses the full upstream commit SHA in
`MOCHI_NATIVE_GVM_REVISION`.

The ABI uses a single VM with serialized calls and loads identical Ruby
packages once per process. Each successful mount owns
its own instance handle until unmount. Dispatch and patch reads run on the
AppKit thread. Native patch and error buffers are borrowed, and AppKit
decodes and copies a complete patch batch before publishing any values.
