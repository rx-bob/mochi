# Mochi Direction C demo

Live demo for E4.S3: a canonical `MyCounter` component compiled to mruby
bytecode and executed by the Goose WASM runtime.

## Run

```sh
cd /Users/bob/repos/mochi
node demo/server.js
```

Open <http://localhost:9844>.

The server serves:

- `/` — this demo page
- `/demo/*` — page assets
- `/poc_yiseq/*` — built `mochi.js`, `mochi.wasm`, and `.chi` bytecode
- `/api/users` — mock endpoint for the existing `UserList` component

No build is required. The page uses the artifacts produced by
`poc_yiseq/build.sh`; rebuild first if `my_counter.chi` is missing or stale.

## What to try

1. Click **Increment** inside the live component.
2. Watch `Count` and the shadow DOM snippet update.
3. Use **Dispatch +1** / **Dispatch −1** to send clicks through the external
   demo controls.
4. Inspect the live event log for the `click → increment` and `render` entries.
5. Scroll to **Same VM, other components** to use the existing `Counter`,
   `TodoList`, and `UserList` bytecode in the same VM.

## What it proves

- `@tag_name = "my-counter"` becomes a Ruby `tag_name` method and is validated
  against the host element.
- `{count}` template bindings become `#{@count}`.
- `onclick="{increment}"` becomes `data-action="increment"` and is delegated
  from the shadow root.
- `def css` is fetched through the C bridge and applied as one persistent
  `<style>` inside an open shadow root.
- `def mounted` runs during `mochi_hydrate_component`; `data-mounted="1"` is
  visible in the first render.
- All component behavior stays in `.chi` bytecode. Component JavaScript is zero
  bytes.

## Files

- `index.html` — page structure and live component mounts
- `demo.css` — demo-only presentation; light-DOM styles for the older PoC components
- `demo.js` — telemetry, artifact measurement, external dispatch, event log
- `server.js` — dependency-free local static server plus `/api/users`
