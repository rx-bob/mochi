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
    "StationSans": "public/station-sans.woff2"
  }
}
```

`root` is the component's `@tag_name`. Give `app_id` a stable reverse DNS
identifier and `display_name` the name users should see. `fonts` maps CSS family
names to local WOFF2, OTF or TTF files under `public/`. Use an empty object
when the screen uses only generic fonts. Mount the declared tag in your
`index.html` and define its `@font-face` URLs there. The native packager uses
the declared asset paths.

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
