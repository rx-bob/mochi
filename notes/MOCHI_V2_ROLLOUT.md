# yiseq Rollout Plan

**Goal:** Make the MRI-WASM compilation pipeline (yiseq) the default build path, while keeping the opal/QuickJS transpiler as a fully maintained fallback backend. Achieve a browser-clickable end-to-end demo with robust testing at every layer.

**Non-Goal:** Removing or deprecating the opal backend. Both pipelines remain first-class citizens; yiseq is simply the default.

---

## Testing Philosophy

Every epic and story in this plan treats testing as a first-class deliverable, not an afterthought. The following testing layers apply universally:

1. **Ruby Unit Specs** — Every Ruby class has comprehensive `*_spec.rb` coverage.
2. **JS Unit Tests (Node.js)** — Every JS module (`bootstrapper.js`, `painter.js`, `event_bridge.js`) has Node-based tests with mock DOM/WASM environments.
3. **Build Pipeline Tests** — Every build step (transpilation, `.yiseq` generation, `index.html` emission) is verified end-to-end in temp directories.
4. **E2E Parity Tests** — The same component is built under both yiseq and opal pipelines; a headless browser verifies identical DOM output and identical event behavior.
5. **Smoke Tests** — The WASM binary instantiates, exports ABI functions, and runs a minimal `.yiseq` payload.
6. **Performance Regression Tests** — Benchmark baselines are recorded in CI; any PR that regresses build time, binary size, or hydration latency by >10% fails CI.

---

## Epic 1: Production-Ready WASM Binary

**Deliverable:** A `mochi-ruby-micro.wasm` binary that loads in a browser, is under 800KB compressed, and exports all required ABI functions.

### Story 1.1: Emscripten Browser Build

**Details:**
The current WASI SDK build produces a binary that depends on `wasi_snapshot_preview1` imports and crashes in `wasmtime` due to setjmp/longjmp issues. Emscripten is purpose-built for browsers and handles exceptions via JavaScript trampolines, eliminating the longjmp problem. It also provides JS glue code (`mochi-ruby-micro.js`) that sets up memory, imports, and pre-main initialization automatically.

**Tasks:**
- Add `scripts/build_micro_wasm_emscripten.sh` that uses `emcc` instead of `wasm32-wasip1-clang`.
- Target `-s WASM=1 -s SIDE_MODULE=0 -s EXPORTED_FUNCTIONS=[]` plus `EMSCRIPTEN_KEEPALIVE` for `mochi_*` exports.
- Compile `mochi_stubs.c` + `mochi_bridge.c` + MRI Ruby into a single Emscripten-linked `.wasm`.
- Output both `.wasm` and companion `.js` glue to `build_wasm/`.

**Acceptance Criteria:**
- `emcc --version` is checked by the build script; exits with clear error if missing.
- `node -e "WebAssembly.instantiate(...)"` using only Emscripten's generated JS glue succeeds without manual WASI imports.
- The binary exports `memory`, `mochi_hydrate_component`, `mochi_process_events`, `mochi_render_buffer_offset`, `mochi_event_buffer_offset`, `mochi_load_iseq`, `mochi_malloc`.
- Smoke test passes in Node.js with Emscripten glue (no `wasmtime` required).
- **Testing:** Ruby spec verifies all 7 exports exist and are callable via `Module.ccall`. JS Node spec verifies `WebAssembly.Module.exports()` contains every export name.

---

### Story 1.2: Binary Size Optimization (Under 2MB)

**Details:**
The current raw binary is ~15MB. We must strip it aggressively to hit a practical lazy-loaded WASM budget. Emscripten provides `-Os`, `-Oz`, `-s FILESYSTEM=0`, `-s SUPPORT_ERRNO=0`, and dead-code elimination. We also need to remove unused Ruby extensions, disable the parser (Story 3.2), and verify gzip/Brotli compression.

**Tasks:**
- Audit `build_wasm/mochi-ruby-micro.wasm` with `wasm-objdump -x` to identify the largest sections.
- Add Emscripten flags: `-s FILESYSTEM=0`, `-s SUPPORT_ERRNO=0`, `-s ASSERTIONS=0`, `-s SAFE_HEAP=0`, `-s STACK_OVERFLOW_CHECK=0`, `-s ERROR_ON_UNDEFINED_SYMBOLS=1`.
- Re-run `wasm-opt -Oz --strip-debug --strip-producers --strip-target-features --dce --remove-unused-module-elements --remove-unused-names --merge-locals` post-link.
- Generate `.wasm.gz` and `.wasm.br` pre-compressed assets in the build script.

**Acceptance Criteria:**
- Gzip-compressed `.wasm` is strictly <= 2,097,152 bytes (2 MB).
- Brotli-compressed `.wasm` is <= 1,572,864 bytes (1.5 MB) for CDN edge caching.
- The smoke test prints the gzip size and fails (non-zero exit) if over budget.
- `node` can still instantiate and call `mochi_render_buffer_offset()` after optimization.
- **Testing:** Build script spec enforces the 2 MB budget as a hard assertion. Size regression spec fails CI if the binary grows by >5% from the previous commit's baseline (stored in `.mochi_size_baseline.json`).

---

### Story 1.3: Binary Delivery in Build Output

**Details:**
The build pipeline currently emits `.yiseq` and `index.html` but does not copy `mochi-ruby-micro.wasm` into the user's build directory. We need to treat the WASM runtime as a build artifact that is versioned, copied, and served alongside the app.

**Tasks:**
- Add `wasm_runtime: String` param to `BuildMain#build` pointing to the compiled `.wasm` file.
- In `BuildMain`, copy the runtime to `#{output_dir}/mochi-ruby-micro.wasm` (and `.wasm.gz` / `.wasm.br` if they exist).
- Add a `mochi-runtime-manifest.json` in the build output tracking version and size for cache-busting.
- Update `Transpiler#generate_index_html` to reference the runtime with a cache-busting query string.

**Acceptance Criteria:**
- After `mochi -i ./lib -o ./build`, the build directory contains `mochi-ruby-micro.wasm` (and `.gz`/`.br` variants).
- `index.html` references `mochi-ruby-micro.wasm?v={hash}` where hash is the first 8 chars of the file SHA256.
- The build fails with a clear message if the runtime binary is missing or exceeds the size budget.
- **Testing:** Ruby spec verifies `mochi-runtime-manifest.json` is valid JSON with `version`, `size_raw`, `size_gzip` fields. E2E spec verifies the browser fetches `.wasm?v={hash}` and receives `200 OK`.

---

## Epic 2: Browser Integration & Serving

**Deliverable:** The Mochi dev server and build output serve the WASM runtime correctly with proper MIME types, CORS headers, and compression negotiation, so a browser can fetch and instantiate it.

### Story 2.1: Emscripten JS Glue Integration

**Details:**
Emscripten produces a companion `.js` file that handles memory allocation, pre-main initialization, and import object setup. Our hand-written `bootstrapper.js` currently tries to do this manually and references WASI imports that browsers don't provide. We need to either (a) adopt Emscripten's generated glue as the bootstrapper base, or (b) write a minimal custom loader that calls the Emscripten glue, then adds our `IntersectionObserver` and `EventBridge` on top.

**Tasks:**
- Keep current `bootstrapper.js` for the opal fallback pipeline (unchanged).
- Create `bootstrapper_v2.js` that loads Emscripten's generated `mochi-ruby-micro.js` glue, then wraps it with lazy loading, `IntersectionObserver`, and `EventBridge` wiring.
- Ensure the Emscripten glue exposes `Module` with `cwrap('mochi_hydrate_component', ...)` and `ccall`.
- Update `wasm_boot.js` to use `Module.ccall('mochi_hydrate_component', ...)` instead of raw `wasm.exports`.

**Acceptance Criteria:**
- `bootstrapper_v2.js` is emitted into `index.html` inline (minified when `--minify` is set).
- A browser opening `index.html` with DevTools Network tab shows a single `mochi-ruby-micro.wasm` fetch when a `[data-mochi-hydrate]` element enters the viewport.
- No `404` for `.wasm` or `.yiseq` files in DevTools.
- The `Module` object is accessible in the browser console after load.
- **Testing:** JS Node spec mocks `WebAssembly` and `Module` to verify `bootstrapper_v2.js` calls `cwrap` with correct signatures. E2E spec verifies the Network tab shows exactly one `.wasm` fetch per page load.

---

### Story 2.2: Dev Server `.wasm` Serving

**Details:**
The existing `DevServer` (WEBrick-based) serves `.yiseq` with `application/octet-stream` but does not handle `.wasm` (needs `application/wasm`), `.wasm.gz` (needs `Content-Encoding: gzip`), or `.wasm.br` (needs `Content-Encoding: br`). Browsers also need correct CORS headers for `SharedArrayBuffer` (if we later use it) and `Cross-Origin-Resource-Policy`.

**Tasks:**
- Add MIME type mapping in `dev_server.rb`: `.wasm` -> `application/wasm`, `.yiseq` -> `application/octet-stream`.
- Add `Content-Encoding: gzip` when serving `.gz` files; `Content-Encoding: br` for `.br` files.
- Add `Access-Control-Allow-Origin: *` and `Cross-Origin-Resource-Policy: cross-origin` headers.
- Add `Content-Type: application/wasm` + `Content-Encoding: gzip` when browser sends `Accept-Encoding: gzip`.

**Acceptance Criteria:**
- `curl -I http://localhost:8080/mochi-ruby-micro.wasm` returns `Content-Type: application/wasm`.
- `curl -I -H "Accept-Encoding: gzip" http://localhost:8080/mochi-ruby-micro.wasm` returns `Content-Encoding: gzip`.
- Browser DevTools shows `.wasm` loaded with `200 OK` and `Content-Encoding: gzip` when served.
- **Testing:** Ruby spec verifies all three MIME types and encodings via mock HTTP requests. E2E spec uses `fetch()` in a headless browser to verify the same.

---

### Story 2.3: Build Pipeline Integration

**Details:**
The CLI (`mochi.rb`) currently defaults to the opal path. We need to switch the default to yiseq while keeping `--opal` as an explicit fallback flag. The `build_main.rb` orchestration must call the new yiseq path unless the user explicitly requests opal.

**Tasks:**
- Change `mochi.rb` default `command` from `:build` (opal) to `:build_v2` (WASM pipeline).
- Add `--opal` flag to `mochi.rb` that forces the old opal/QuickJS transpiler.
- Update `BuildMain#build` signature to accept `runtime_path: nil` and auto-detect the latest `build_wasm/mochi-ruby-micro.wasm`.
- If the WASM runtime is missing and `--opal` is not set, print a helpful error with `run ./scripts/build_micro_wasm_emscripten.sh first`.

**Acceptance Criteria:**
- `mochi -i ./lib -o ./build` (no flags) produces yiseq output: `index.html` with WASM bootstrapper + `.yiseq` + `.wasm`.
- `mochi -i ./lib -o ./build --opal` produces legacy output: `bundle.js` via opal with no WASM references.
- If `build_wasm/mochi-ruby-micro.wasm` is missing, the build exits `1` with a clear message pointing to the build script.
- **Testing:** Spec verifies both `--opal` and default paths produce distinct, correct output artifacts. E2E parity spec builds the same component under both pipelines and verifies the initial `index.html` DOM is byte-for-byte identical (modulo script content).

---

## Epic 3: Component Runtime Feature Parity

**Deliverable:** A yiseq component written in Ruby can handle events, update state, and re-render the DOM via the shared memory bridge, matching the behavior of the current opal components.

### Story 3.1: Event Binding in Ruby Components

**Details:**
Current opal components use `data-on-click`, `data-on-input`, etc. The yiseq compiler parses these and generates JS event listeners. For yiseq WASM, events must be serialized by `event_bridge.js`, written to WASM memory, and dispatched by `Mochi::EventLoop.tick`. We need to verify that the existing Ruby component syntax (e.g., a method called `increment` triggered by click) works end-to-end.

**Tasks:**
- Verify `RubyUnderstander` extracts `data-on-click="increment"` from HTML templates.
- Ensure `EventBridge` writes the correct payload (`"increment"`) into the event buffer.
- Verify `Mochi::EventLoop.tick` reads the payload and dispatches to `component.increment`.
- Verify `increment` mutates `@count`, `render` produces a new VDOM, and `Differ` emits `UPDATE_TEXT`.

**Acceptance Criteria:**
- A Ruby component with `def html; '<span data-on-click="increment">Count: {count}</span>'; end` and `def increment; @count += 1; end` compiles successfully under both `--opal` and default yiseq.
- Clicking the element in a browser triggers the event -> WASM -> Ruby method -> VDOM diff -> JS Painter -> DOM update (yiseq path).
- The DevTools console shows zero errors during the event round-trip.
- **Testing:** Ruby spec simulates the event buffer write -> tick -> render buffer read and verifies `UPDATE_TEXT` for the counter span. E2E parity spec clicks the counter under both yiseq and opal builds and asserts the text changes to the same value.

---

### Story 3.2: CSS Injection via Shadow DOM or Style Tag

**Details:**
opal components currently inject CSS into the page via a `<style>` tag or shadow DOM. yiseq components have a `css` method but the runtime does not yet inject it. We need the JS Painter (or a pre-hydration step) to create a `<style>` tag with the component's CSS when the component first mounts.

**Tasks:**
- Store component CSS in `data-mochi-css` attribute during SSR (in `generate_index_html`).
- Update `Painter` or `bootstrapper_v2.js` to read `data-mochi-css`, create a `<style>` element scoped to the component's subtree, and inject it.
- Ensure CSS is only injected once per component class (deduplicate by tag name).

**Acceptance Criteria:**
- `index.html` contains `data-mochi-css="...base64 or raw CSS..."` on each custom element.
- After hydration, a `<style>` tag exists in the DOM with the component's rules.
- Multiple instances of the same component share a single style block (no duplication).
- The counter component's `span { font-weight: bold; }` is visually active after WASM load.
- **Testing:** Ruby spec verifies `data-mochi-css` is present in generated HTML. JS Node spec verifies `Painter` injects exactly one `<style>` per tag name. E2E spec asserts `getComputedStyle(span).fontWeight === 'bold'` under both yiseq and opal.

---

### Story 3.3: DevGround Components Ported to yiseq

**Details:**
The `devground` project contains real-world components (router, feather icons, forms). We must verify they compile under yiseq without opal-specific APIs (`Native`, `$$`, etc.) and that the yiseq runtime can hydrate them. This is the feature-parity gate.

**Tasks:**
- Audit `devground/components/lib/` for opal-specific calls.
- Replace `Native` usage with plain Ruby objects or DOM-bridge methods.
- Ensure `MochiRouter`, `FeatherIcon`, and form components define `#initialize`, `#html`, and `#css` correctly.
- Run a full yiseq build on `devground` and open it in the browser.

**Acceptance Criteria:**
- `mochi -i devground/lib -o devground/build` succeeds with zero compilation errors.
- `mochi -i devground/lib -o devground/build --opal` also succeeds (no regression).
- The built `index.html` renders the devground landing page with all components visible under both pipelines.
- Navigation (if router is present) works without full page reloads under both pipelines.
- Feather icons render as SVGs with correct CSS styling under both pipelines.
- Any failures produce actionable error messages, not raw WASM stack traces.
- **Testing:** CI runs both `mochi build` (yiseq) and `mochi build --opal` on `devground` and fails if either errors. Visual regression spec (Playwright screenshot comparison) asserts pixel-perfect match between yiseq and opal renders of the landing page.

---

## Epic 4: Default Pipeline Switch

**Deliverable:** The yiseq pipeline is the default user experience; opal is an explicit opt-in fallback. Both pipelines remain fully maintained. All documentation, CLI help, and examples point to yiseq as default.

### Story 4.1: CLI Flag Migration

**Details:**
The current `mochi.rb` CLI has flags like `--tc`, `--mini`, `--compress-yiseq`. We need to add `--v2` (default) and `--opal` (fallback), update the help text, and ensure backward compatibility for scripts that call `mochi build`.

**Tasks:**
- Make `:build_v2` the new default `:build`. Keep `:build_opal` as an alternate command.
- Add `--opal` flag that maps to `:build_opal`.
- Add `--v2` flag that explicitly selects yiseq (even though it's default, for clarity in scripts).
- Update `BuilderMan` and `BuildMain` to branch on pipeline type.
- Update `--help` output to describe yiseq as default and opal as maintained fallback.

**Acceptance Criteria:**
- `mochi --help` shows `build (default: yiseq pipeline)` and `--opal (fallback opal pipeline)`.
- `mochi build -i ./lib -o ./build` uses yiseq without any extra flags.
- `mochi build -i ./lib -o ./build --opal` uses the opal path.
- `mochi build -i ./lib -o ./build --v2` is accepted and equivalent to the default.
- **Testing:** Spec verifies all three flag combinations produce correct command routing. No deprecation warning is printed for `--opal` (it is a supported fallback, not deprecated).

---

### Story 4.2: opal Fallback Isolation

**Details:**
The opal path must remain fully functional. We need to isolate it so it doesn't interfere with yiseq artifacts and can evolve independently. This is architectural separation, not deprecation.

**Tasks:**
- Keep all opal-specific code (`opal_runtime_generator.rb`, `opal_builder.rb`, etc.) in `compiler_rb/src/opal/` (already exists; do not move to `legacy/`).
- Update `BuildMain` to call `opal::BuildMain` only when `--opal` is set.
- Ensure yiseq and opal build artifacts never collide (e.g., opal produces `bundle.js`, yiseq produces `runtime.js` + `.wasm`).
- Add CI job that runs the full opal spec suite on every PR.

**Acceptance Criteria:**
- opal build passes its existing specs on every commit.
- yiseq build output never contains opal artifacts unless `--opal` is used.
- No circular requires between `opal/` and yiseq runtime code.
- **Testing:** CI runs both spec suites (yiseq + opal) in parallel. A spec verifies that running `--opal` then default yiseq on the same output dir produces non-colliding artifacts.

---

### Story 4.3: Documentation & README Update

**Details:**
The current README describes the opal architecture as the only path. We need to rewrite it to present yiseq as the default while documenting opal as a maintained fallback for environments where WASM is unavailable or undesirable.

**Tasks:**
- Rewrite `README.md` with yiseq as the primary architecture.
- Add a "Getting Started" section: install, write a component, build, serve.
- Document the `data-mochi-hydrate` SSR concept and lazy WASM loading.
- Add "Fallback: opal Backend" section explaining when and how to use `--opal`.
- Add troubleshooting for common WASM issues: CORS, MIME types, size budget, `emcc` not installed.
- Keep old opal docs in `docs/opal/` for users who need the fallback.

**Acceptance Criteria:**
- A new user can follow `README.md` to build and run a counter component in under 5 minutes using the default yiseq path.
- The README clearly explains what `.yiseq` files are and why the browser loads them.
- The README documents `--opal` as a supported fallback, not a deprecated legacy path.
- Troubleshooting section covers `404 for .wasm`, `CORS error`, `WASM runtime not found`, and `emcc not installed`.
- **Testing:** A "docs CI" spec parses `README.md` and asserts every code block is valid shell or Ruby syntax. A link-checker spec verifies all internal links resolve.

---

## Epic 5: End-to-End Browser Verification

**Deliverable:** A browser-based demo that provably works: SSR shell -> lazy WASM load -> hydration -> click -> DOM update, with all layers verified under both yiseq and opal pipelines.

### Story 5.1: Counter Click Demo

**Details:**
The "hello world" of yiseq: a counter component that increments on click. This must work in Chrome, Firefox, and Safari without polyfills (beyond what Emscripten provides). The same component must also work under `--opal` to prove parity.

**Tasks:**
- Create `examples/v2-counter/` with a single `lib/counter.rb` component.
- Add a `Makefile` or `justfile` that runs both `mochi build` (yiseq) and `mochi build --opal` + `python3 -m http.server`.
- Record a Loom/screenshot of the click -> increment flow for documentation.
- Add an E2E test (Playwright) that clicks the counter and asserts the text changes under both yiseq and opal builds.

**Acceptance Criteria:**
- `examples/v2-counter/` builds and serves with one command for both yiseq and opal.
- Clicking the counter increments the displayed number within 200ms of WASM load (yiseq) or JS load (opal).
- The demo works in Chrome 120+, Firefox 120+, Safari 17+ under both pipelines.
- E2E test passes in CI (headless browser) for both yiseq and opal.
- **Testing:** Playwright E2E spec asserts `span.innerText === 'Count: 1'` after one click under both pipelines. Screenshot comparison spec asserts yiseq and opal renders are visually identical after hydration.

---

### Story 5.2: Dev Server Hot Reload for yiseq

**Details:**
The current `mochi dev` watches files and rebuilds opal. We need equivalent hot-reload for yiseq: when a `.rb` component changes, the dev server rebuilds `.yiseq` and reloads the page (or ideally patches the component without reload). The opal `mochi dev --opal` must continue to work unchanged.

**Tasks:**
- Update `DevServer` file watcher to trigger `.yiseq` regeneration on `.rb` change when running default yiseq mode.
- Invalidate the browser's `.yiseq` cache by changing the query string hash.
- For MVP: full page reload on change. For stretch goal: inject new `.yiseq` and re-hydrate.
- Ensure `mochi dev --opal` still rebuilds opal bundle and reloads as before.

**Acceptance Criteria:**
- Saving `lib/counter.rb` triggers a rebuild in < 2 seconds under `mochi dev`.
- The browser auto-reloads and shows the updated component.
- No manual `mochi build` is needed during development.
- If a build error occurs, the browser shows a full-screen overlay with the Ruby backtrace.
- `mochi dev --opal` behaves identically to before (no regression).
- **Testing:** E2E spec launches `mochi dev`, modifies `lib/counter.rb`, and asserts the browser reloads within 3 seconds with updated content. Separate spec verifies `--opal` hot reload still works.

---

### Story 5.3: Performance Benchmarks

**Details:**
Before declaring yiseq "production ready," we need numbers: time to interactive, WASM fetch size, hydration latency, event round-trip time, and memory usage. We also need to ensure opal performance does not regress.

**Tasks:**
- Add `examples/v2-benchmark/` with 100 components on one page.
- Use `performance.now()` in `bootstrapper_v2.js` to log: `wasm_fetch_ms`, `hydrate_ms`, `first_click_ms`.
- Add `performance.now()` in opal bootstrapper to log equivalent metrics: `bundle_load_ms`, `first_click_ms`.
- Add a Ruby spec that benchmarks `EventLoop.tick` with 100 events.
- Document the benchmark results in `docs/performance.md`.

**Acceptance Criteria:**
- WASM binary loads (on fast 4G throttling) in < 3 seconds.
- Hydration of 10 components completes in < 500ms after WASM instantiation.
- Click-to-paint latency is < 16ms (one frame) for simple components.
- Memory usage stays under 128MB for a page with 50 components.
- opal bundle load time does not regress by >10% from the current baseline.
- **Testing:** A `benchmark.sh` script runs both yiseq and opal benchmarks and outputs JSON. CI stores benchmark results as artifacts and fails if any metric exceeds its threshold. The Ruby `EventLoop.tick` benchmark spec asserts 100 events are processed in < 50ms.

---

## Epic 6: E2E Parity & Testing Infrastructure

**Deliverable:** A comprehensive test suite that verifies yiseq and opal pipelines produce identical behavior for every supported component feature, with automated CI enforcement.

### Story 6.1: E2E Test Framework Setup

**Details:**
We need a unified E2E framework that can build a component under both pipelines, serve it, and run the same assertions. Playwright is the best choice because it supports headless browsers, screenshots, and network interception.

**Tasks:**
- Add Playwright (or Puppeteer) as a dev dependency in `e2e/package.json`.
- Create `e2e/runner.rb` that:
  1. Builds the same component under yiseq and opal into temp dirs.
  2. Spins up a `DevServer` for each.
  3. Runs the same Playwright test file against both servers.
  4. Reports parity: pass if both produce the same DOM + screenshots.
- Add `e2e/specs/counter_click.spec.js` as the first shared test.

**Acceptance Criteria:**
- `bundle exec ruby e2e/runner.rb --spec=counter_click` runs the test against both yiseq and opal and exits `0` only if both pass.
- A mismatch (e.g., yiseq renders "Count: 1" but opal renders "Count: 2") produces a diff screenshot and a detailed assertion failure.
- CI runs `e2e/runner.rb` for all specs in `e2e/specs/` on every PR.
- **Testing:** The runner itself has a Ruby spec that verifies it can start/stop mock servers and invoke Playwright correctly.

---

### Story 6.2: Feature Parity Matrix

**Details:**
We need an explicit, checkable list of every component feature and whether it works in yiseq, opal, or both. This is the "contract" between the two pipelines.

**Tasks:**
- Create `docs/parity_matrix.md` with rows for every feature: `initialize`, `html`, `css`, `data-on-click`, `data-on-input`, `data-on-change`, `data-each`, `data-if`, `router`, `forms`, `svg/icons`, `shadow-dom`.
- Columns: `yiseq`, `opal`, `E2E Test File`, `Notes`.
- Fill in the matrix by running E2E tests. Mark features as `supported`, `partial`, or `not-yet`.
- Update the matrix on every PR that changes parity.

**Acceptance Criteria:**
- `docs/parity_matrix.md` exists and is checked into version control.
- Every `supported` cell has a linked E2E test file.
- CI enforces that no PR can downgrade a `supported` cell to `partial` or `not-yet` without an explicit override flag.
- **Testing:** A Ruby spec parses `docs/parity_matrix.md` and verifies every `supported` row has a corresponding file in `e2e/specs/`. Another spec verifies the matrix markdown is well-formed.

---

### Story 6.3: CI Pipeline for Dual-Backend Testing

**Details:**
Every PR must be tested against both yiseq and opal. The CI pipeline should run Ruby specs, JS specs, build tests, E2E tests, and benchmarks in parallel where possible.

**Tasks:**
- Add `.github/workflows/ci.yml` (or update existing) with jobs:
  - `ruby-specs-v2`: Run all yiseq specs.
  - `ruby-specs-opal`: Run all opal specs.
  - `js-specs`: Run Node-based tests for `bootstrapper.js`, `painter.js`, `event_bridge.js`.
  - `e2e-parity`: Run `e2e/runner.rb` for all specs.
  - `benchmarks`: Run `benchmark.sh` and store artifacts.
  - `size-check`: Verify `mochi-ruby-micro.wasm` gzip size <= 800KB.
- Configure GitHub Actions to run on `push` and `pull_request`.
- Use caching for `bundle install`, `npm install`, and `emcc` toolchain.

**Acceptance Criteria:**
- CI passes for both yiseq and opal on every PR.
- A PR that breaks either pipeline is blocked from merging.
- CI artifacts include: build output screenshots, benchmark JSON, `mochi-runtime-manifest.json`.
- **Testing:** A "meta-spec" verifies that `.github/workflows/ci.yml` contains all required jobs and that each job references a valid spec file.

---

## Appendix A: Rollout Checklist

Before merging yiseq as default:

- [ ] Epic 1 complete: Emscripten binary < 800KB gzip
- [ ] Epic 2 complete: Dev server serves `.wasm` with correct MIME + encoding
- [ ] Epic 3 complete: Counter click works in all major browsers (yiseq)
- [ ] Epic 3 complete: Counter click still works under `--opal` (no regression)
- [ ] Epic 4 complete: `--opal` is opt-in; `--v2` is default; both documented
- [ ] Epic 4 complete: opal specs still pass in CI
- [ ] Epic 5 complete: E2E test passes for both yiseq and opal
- [ ] Epic 5 complete: Performance benchmarks documented; no opal regression
- [ ] Epic 6 complete: E2E parity matrix exists and is enforced by CI
- [ ] `MOCHI_yiseq.md` stories 1.1-7.2 are all marked "Done"
- [ ] `README.md` rewritten for yiseq; opal fallback documented
- [ ] CI passes all jobs: Ruby specs (both backends), JS specs, E2E, benchmarks, size-check
- [ ] No regressions in `devground` build under either `--opal` or default yiseq
- [ ] `docs/parity_matrix.md` shows 100% feature parity between yiseq and opal for all `devground` components

---

## Appendix B: opal Backend Preservation Policy

The opal/QuickJS transpiler is **not deprecated**. It remains a fully supported fallback backend for:

- Environments where `emcc` cannot be installed (CI containers, restricted build environments).
- Debugging scenarios where the WASM runtime is misbehaving and developers need a known-good path.
- Older browsers that do not support WebAssembly ( diminishing but non-zero user base).
- Rapid prototyping where the ~10-15 minute Emscripten build is too slow.

Policy:
1. opal specs run in CI on every PR.
2. opal build path is tested by the E2E parity runner on every PR.
3. No yiseq code change may break opal without an explicit RFC and migration plan.
4. opal-specific files live in `compiler_rb/src/opal/` and are not moved to `legacy/`.
5. The `--opal` flag is documented in `README.md` as a supported option.

---

*Document version: 2.0*
*Target date for default switch: TBD after Epic 5 and Epic 6 are complete*
