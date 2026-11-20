# Portable projects

Put `mochi-portable.json` at the project root to build one Mochi screen for
the browser and the experimental macOS host.

```json
{
  "version": 1,
  "root": "record-inspector",
  "app_id": "org.mochi.stations",
  "display_name": "Stations",
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
and single-class flex styles. Child composition and host-backed Ruby
operations require support on both hosts before they enter the profile.
See the [station inspector](../e2e/fixtures/clay_inspector) for a working
project and its shared Ruby scenario.

## Native development build

The AppKit host links a matching `mochi-gvm` source checkout. Build its
standalone Goose artifacts first and point `MOCHI_GVM_DIR` to that checkout
when it is outside the default sibling directory. The host requires native
ABI v1 and validates the scene's capacity fingerprint before loading Ruby.
Hosted macOS CI uses the full upstream commit SHA in
`MOCHI_NATIVE_GVM_REVISION`.

The ABI uses a single VM with serialized calls. Each successful mount owns
its own instance handle until unmount. Dispatch and patch reads run on the
AppKit thread. Native patch and error buffers are borrowed, and AppKit
decodes and copies a complete patch batch before publishing any values.
