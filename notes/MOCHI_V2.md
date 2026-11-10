# Mochi V2: Extreme MRI Architecture Plan (Ruby Compiler Edition)

This document outlines the extreme performance architecture for Mochi, delivering **100% MRI Ruby in the browser** while hitting the **14kB initial payload limit** and bypassing standard WebAssembly-to-JS interop bottlenecks.

This revision adapts the original Extreme MRI plan to the **Ruby-based compiler** (`compiler_rb/`), which was ported from Crystal. All build tooling, entrypoints, and compiler internals are now implemented in Ruby with Sorbet type annotations.

This is a massive engineering undertaking. It requires a custom fork of MRI Ruby, deep C-level modifications, a custom WebAssembly build pipeline, and a highly optimized memory-sharing architecture.

---

## Epic 1: The 14kB Base - Hollow Shells & Server-Side Generation
**Goal:** Guarantee instant page loads by rendering the initial HTML on the server. The first network request must contain the fully styled UI, strictly under 14kB compressed.

### Story 1.1: Static Component HTML Generator
*   **Details:** The Mochi Ruby compiler must execute or evaluate the Ruby component's `#html` and `#css` definitions at build time.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/webcomponents/component_generator.rb`
    *   Modify the `ComponentGenerator#generate` method to emit standard HTML strings where the internal template of the component is rendered as Light DOM or Declarative Shadow DOM.
    *   Strip out dynamic bindings (`{count}`) and replace them with their initial `#initialize` values.
*   **Acceptance Criteria:**
    *   The build outputs an `index.html` with fully expanded Web Components.
    *   Components contain `data-mochi-hydrate="true"` and `data-mochi-state="{...}"` (JSON serialized initial state).

### Story 1.2: The Micro-Bootstrapper (Intersection Observer)
*   **Details:** A highly optimized (~1-2kB) JavaScript file that defers loading the WASM engine until a component is visible.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/js/bootstrapper.js` (or `packages/mochi-runtime/bootstrapper.js`)
    *   Initialize an `IntersectionObserver`.
    *   When a `[data-mochi-hydrate]` element intersects:
        1. Fetch `mochi-ruby-micro.wasm` (deduplicated/cached promise).
        2. Fetch `[component_name].yiseq` (the compiled bytecode).
        3. Allocate the `WebAssembly.Memory` object (crucial for the Shared Memory bridge).
        4. Instantiate the WASM module with the shared memory.
*   **Acceptance Criteria:**
    *   Network tab confirms `.wasm` and `.yiseq` files are only requested when the component scrolls into the viewport.

---

## Epic 2: The AOT Bytecode Pipeline (Cross-Architecture Challenge)
**Goal:** Shift parsing from the browser to the build server. **CRITICAL CHALLENGE:** `RubyVM::InstructionSequence.to_binary` is highly dependent on word size (32-bit vs 64-bit) and endianness. Since WASM is 32-bit little-endian, a 64-bit native Ruby cannot generate compatible bytecode for it.

### Story 2.1: The WASM-Native ISeq Dumper
*   **Details:** To guarantee bytecode compatibility, the Mochi compiler must use a headless WASM runtime (like Wasmtime or Wasmer) during the build step to generate the `.yiseq` files.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/entrypoints/transpiler.rb`
    *   Bundle a CLI tool (e.g., `wasmtime`) with the Mochi compiler.
    *   During transpilation, execute: `wasmtime run mochi-ruby-micro.wasm -- dump_iseq counter.rb > counter.yiseq`.
    *   The WASM Ruby instance runs a script that calls `RubyVM::InstructionSequence.compile_file('counter.rb').to_binary` and writes to `STDOUT`.
*   **Acceptance Criteria:**
    *   The build pipeline successfully outputs 32-bit, WASM-compatible `.yiseq` binary files regardless of the host OS (Mac/Linux/Windows).

### Story 2.2: Vite Plugin Integration for Bytecode Assets
*   **Details:** Integrate the `.yiseq` generation into the modern Vite build graph.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/js/vite_plugin_mochi.rb` (or `packages/vite-plugin-mochi/index.ts` if kept in TypeScript)
    *   When Vite resolves a `.rb` import, the plugin intercepts it, triggers the WASM ISeq Dumper, and emits the `.yiseq` file as a static asset using Vite's `this.emitFile`.
    *   The JS output becomes `export default __VITE_ASSET_URL__;`.
*   **Acceptance Criteria:**
    *   Vite development server hot-reloads `.yiseq` files when `.rb` files change.

---

## Epic 3: The Micro-WASM Runtime (Forking & Stripping MRI)
**Goal:** Create a custom, ultra-lean build of `ruby.wasm` by ripping out the parser, compiler, and unused C extensions.

### Story 3.1: Forking MRI & Build Automation
*   **Details:** Establish a reproducible build environment for compiling a custom Ruby WASM binary.
*   **Technical Details:**
    *   **Target:** `scripts/build_micro_wasm.sh`
    *   Clone a specific tag of `ruby/ruby`.
    *   Configure with: `--target=wasm32-unknown-wasi --disable-install-doc --disable-rubygems --with-out-ext=pty,readline,syslog,openssl,socket,ripper`.
*   **Acceptance Criteria:**
    *   Script reliably produces a working `ruby.wasm` via Emscripten/WASI.

### Story 3.2: Surgical Removal of `parse.y`
*   **Details:** The heaviest part of Ruby is the parser. Since we only ingest `.yiseq` binaries, we must patch the C source to exclude it.
*   **Technical Details:**
    *   **Target:** Custom C Patch file (`scripts/patches/remove_parser.patch`).
    *   Modify `ruby.c`, `iseq.c`, and `Makefile.in` to mock or bypass functions like `rb_parser_compile_string`.
    *   This will likely break `eval()` and `require` (for raw text), which is expected and desired.
    *   Ensure `rb_iseq_load_from_binary` remains fully functional.
*   **Acceptance Criteria:**
    *   The resulting binary size drops by at least 30-40% compared to a standard stripped WASM build.
    *   The binary successfully executes a `.yiseq` payload but crashes if `eval("1+1")` is called.

### Story 3.3: WASM Binary Optimization
*   **Details:** Run advanced dead-code elimination on the final binary.
*   **Technical Details:**
    *   **Target:** `scripts/build_micro_wasm.sh`
    *   Integrate `wasm-opt -Oz --strip-debug mochi-ruby-micro.wasm -o final.wasm`.
*   **Acceptance Criteria:**
    *   Final WASM file size is minimized (target: < 800kB compressed).

### Story 3.4: Integrate `mochi_bridge.c` into the Ruby Build
*   **Details:** The shared-memory bridge C extension (`compiler_rb/ext/mochi_bridge/mochi_bridge.c`) must be compiled *into* the custom Ruby binary, not loaded as a separate `.so`. WASM Ruby has no dynamic loader.
*   **Technical Details:**
    *   **Target:** `scripts/patches/mochi_bridge_build.patch` + `scripts/build_micro_wasm.sh`
    *   Copy `mochi_bridge.c` into the cloned Ruby source tree under `ext/mochi_bridge/`.
    *   Add an entry to `ext/Setup` (or patch `common.mk`) so the build system compiles `mochi_bridge.o` and links it into `ruby.wasm`.
    *   Ensure the C functions (`write_opcode`, `reset`, `read_buffer`, etc.) are reachable from Ruby as `MochiBridge` module methods inside WASM — they must not rely on `require "mochi_bridge.so"`.
*   **Acceptance Criteria:**
    *   After `build_micro_wasm.sh` completes, `nm mochi-ruby-micro.wasm | grep write_opcode` shows the symbol exists.
    *   `MochiBridge.write_opcode(0x01, 1, "hello")` executes inside `wasmtime run mochi-ruby-micro.wasm` without `LoadError`.

### Story 3.5: Hello World WASM Smoke Test
*   **Details:** Verify the compiled `mochi-ruby-micro.wasm` actually instantiates and can run a minimal `.yiseq` payload end-to-end.
*   **Technical Details:**
    *   **Target:** `spec/scripts/wasm_smoke_spec.rb` + `scripts/smoke_test.sh`
    *   The smoke test script checks for `wasi-sdk` or `emsdk` presence, runs `build_micro_wasm.sh`, gzips the result, and asserts `< 800 kB`.
    *   It then runs `wasmtime mochi-ruby-micro.wasm -- smoke.rb` where `smoke.rb` is a tiny Ruby file that prints `"hello from mochi wasm"`.
    *   If `wasmtime` is not available, the spec checks that `node` can instantiate the binary via `WebAssembly.instantiate`.
*   **Acceptance Criteria:**
    *   `bundle exec rake smoke` passes in under 2 minutes on a clean machine with `wasi-sdk` installed.
    *   The output `mochi-ruby-micro.wasm.gz` is under 800 kB.
    *   A `.yiseq` payload created by `IseqDumper` executes inside the WASM runtime and produces the expected stdout.

---

## Epic 4: The Shared Memory DOM Bridge (Extreme Rendering)
**Goal:** Bypass WASM-to-JS serialization entirely. Ruby will mutate a Virtual DOM and write binary "diff opcodes" directly to a shared memory buffer. JS will read this buffer natively and paint the DOM.

### Story 4.1: The Ruby Virtual DOM
*   **Details:** Implement a lightweight DOM representation strictly in Ruby.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/lib/virtual_node.rb`
    *   Create classes to represent Elements, Text Nodes, and Attributes.
    *   Implement a diffing algorithm (similar to React/Preact) that compares the "old" VDOM tree to the "new" VDOM tree after a state change.
*   **Acceptance Criteria:**
    *   The diffing algorithm successfully outputs a list of logical mutations (e.g., "Change text of node 5", "Add class 'active' to node 2").

### Story 4.2: C-Extension for Memory Buffer Export
*   **Details:** Ruby needs a way to write these diffs to a specific memory address that JS can read.
*   **Technical Details:**
    *   **Target:** `compiler_rb/ext/mochi_bridge/mochi_bridge.c` (New C extension compiled into the custom WASM).
    *   Allocate a static memory buffer (e.g., 64kB) `uint8_t render_buffer[65536]`.
    *   Expose C functions to Ruby: `MochiBridge.write_opcode(type, node_id, ptr)`.
    *   Export the memory offset of `render_buffer` to the WASM exports so JS knows exactly where to look.
*   **Acceptance Criteria:**
    *   Ruby can call `MochiBridge.write_opcode` and the bytes appear at the correct offset in the JS `WebAssembly.Memory` object.

### Story 4.3: The JS Painter (Memory Decoder)
*   **Details:** The JS side of the bridge. It reads the raw bytes and touches the real DOM.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/painter.js`
    *   Create a `DataView` or `Uint8Array` over the WASM memory buffer.
    *   Implement a high-speed `while` loop that reads opcodes:
        *   `0x01` (Create Node): Read tag name pointer, create element, store in JS `Map<NodeId, HTMLElement>`.
        *   `0x02` (Update Text): Read node ID, read string pointer (extract string from WASM memory), update `element.textContent`.
        *   `0x03` (Set Attribute): Read node ID, attr name, attr value.
        *   `0x04` (Append Child): Read parent ID, child ID.
        *   `0xFF` (End of Tick): Stop reading.
*   **Acceptance Criteria:**
    *   The JS loop can process 1,000+ DOM mutations in under 5ms.

---

## Epic 5: The Event Delegation & Routing System
**Goal:** Route user interactions (clicks, inputs) from the browser into the WASM Ruby instance with zero string serialization overhead.

### Story 5.1: Serializing JS Events to Memory
*   **Details:** When a user clicks a button, JS must write the event data into WASM memory.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/event_bridge.js`
    *   Set up a global event listener on `document`.
    *   When an event fires on a component, write an "Event Opcode" into an "Event Buffer" in WASM memory.
    *   Structure: `[Event Type (1 byte), Target Node ID (4 bytes), Data Payload Pointer (4 bytes)]`.
    *   Call an exported WASM function: `mochi_process_events()`.
*   **Acceptance Criteria:**
    *   Clicks successfully trigger the WASM exported function with data available in the memory buffer.

### Story 5.2: Ruby Event Router & Execution Tick
*   **Details:** Ruby must read the event buffer, trigger the correct component method, and flush the VDOM diff.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/lib/event_loop.rb`
    *   Implement `Mochi::EventLoop.tick`.
    *   Read the Event Buffer via `MochiBridge.read_events`.
    *   Find the target component instance based on Node ID.
    *   Call the appropriate method (e.g., `increment`).
    *   Run the VDOM diffing algorithm (Story 4.1).
    *   Write the diff to the Render Buffer (Story 4.2).
    *   Return control to JS.
*   **Acceptance Criteria:**
    *   Clicking "Increment" in the browser results in the Ruby `@count` increasing and the DOM updating in a single synchronous cycle.
    *   Zero runtime errors after 1,000 simulated events.

### Story 5.3: WASM ABI Exports
*   **Details:** JS calls `mochi_process_events()`, `mochi_render_buffer_offset()`, and `mochi_event_buffer_offset()` via `wasm.instance.exports`, but these C functions do not yet exist. They must be added to `scripts/patches/mochi_stubs.c` and marked with `EMSCRIPTEN_KEEPALIVE` so they survive WASM linking.
*   **Technical Details:**
    *   **Target:** `scripts/patches/mochi_stubs.c` + `compiler_rb/src/js/bootstrapper.js`
    *   Add C functions: `mochi_process_events()`, `mochi_render_buffer_offset()`, `mochi_event_buffer_offset()`, `mochi_component_init()`, `mochi_hydrate_state()`.
    *   Each returns a 32-bit unsigned integer (pointer or count) in WASM linear memory coordinates.
    *   `mochi_process_events` iterates the Event Buffer, dispatches events to the Ruby event loop, runs VDOM diff, and flushes the Render Buffer.
    *   `mochi_render_buffer_offset` returns the hard-coded or dynamically-allocated WASM linear-memory offset of the render buffer.
    *   `mochi_event_buffer_offset` returns the offset of the event buffer.
    *   Ensure `rb_define_module_function` is called during `Init_mochi_bridge` (or equivalent init) so Ruby can bind to them.
    *   Bootstrapper must call `wasm.instance.exports.mochi_process_events()` after each event batch, not a stub.
*   **Acceptance Criteria:**
    *   `wasm-objdump -j Export -x mochi-ruby-micro.wasm` lists `mochi_process_events` and `mochi_render_buffer_offset` as exported functions.
    *   Bootstrapper dispatches a click event → JS writes Event Buffer → JS calls `mochi_process_events` → Ruby event loop processes → Render Buffer contains at least one `UPDATE_TEXT` mutation.
    *   No "undefined function" errors in JS console.

---

## Epic 6: State Hydration & Memory Reconstruction

### Story 6.1: VDOM Reconstruction from DOM
*   **Details:** When a component boots, it must build its initial VDOM tree to match the existing HTML, otherwise the first diff will destroy and recreate the whole component.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/lib/component.rb`
    *   During `#initialize`, read `data-mochi-state`.
    *   Execute the component's `#html` method internally to generate the expected VDOM.
    *   Crucially: The JS Painter must traverse the *existing* DOM and assign sequential `Node IDs` to the DOM elements that exactly match the `Node IDs` generated by Ruby's VDOM builder.
*   **Acceptance Criteria:**
    *   When hydration completes, the first VDOM diff produces zero opcodes (because the VDOM perfectly matches the server-rendered HTML).
    *   Subsequent clicks correctly mutate the existing elements without recreating them.

### Story 6.2: JS Painter ID Assignment
*   **Details:** The JS Painter must assign `_mochiNodeId` attribute to every existing DOM node after hydration. This ensures the shared-memory mutation opcodes target the correct real DOM elements.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/painter.js`
    *   After the initial render or hydration, walk the component's subtree in document order.
    *   Assign sequential IDs starting from the root's `Node#id` (which Ruby's VDOM builder generated).
    *   Store a reference `Map<NodeId, HTMLElement>` for fast lookup during paint ticks.
    *   The ID sequence must mirror exactly the order used by Ruby's `VDOMHydrator.from_html` and `VirtualDOM::Node` allocation.
*   **Acceptance Criteria:**
    *   Every DOM node inside a `[data-mochi-hydrate]` component has a `_mochiNodeId` attribute matching its Virtual DOM counterpart.
    *   A `UPDATE_TEXT` mutation for `node_id: 5` correctly updates the element with `_mochiNodeId="5"`.

---

## Epic 7: Integration, Optimization & Production Readiness
**Goal:** Wire the individual WASM/VDOM/Event subsystems into a cohesive runtime, then optimize for real-world deployment.

### Story 7.1: End-to-End WASM Runtime Integration
*   **Details:** Wire the previously isolated subsystems (bootstrapper, WASM module, EventBridge, Painter, EventLoop) into a single boot sequence.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/runtime/boot.rb` (server) + `compiler_rb/src/runtime/boot.wat` or inline JS (`compiler_rb/src/js/wasm_boot.js`)
    *   The bootstrapper (Story 1.2) fetches `.wasm` and `.yiseq`.
    *   On WASM instantiation, call `rb_iseq_load_from_binary` for each `.yiseq` payload.
    *   Invoke the Ruby component's `#new`, then `#hydrate` with the server-rendered HTML and `data-mochi-state`.
    *   Start the global `EventBridge` (Story 5.1) and wire it to `mochi_process_events` (Story 5.2).
    *   The JS Painter (Story 4.3) enters its first read loop; if zero opcodes are returned, it confirms hydration success.
*   **Acceptance Criteria:**
    *   A full page with one server-rendered component can be opened, the bootstrapper loads the WASM runtime lazily, and a click on "Increment" updates the DOM via the shared-memory bridge without reloading the page.

### Story 7.2: Production Build Optimizations
*   **Details:** Minimise the final JS & WASM bundle, remove dead opcodes, and inline small components where beneficial.
*   **Technical Details:**
    *   **Target:** `compiler_rb/src/entrypoints/transpiler.rb`, `compiler_rb/src/js/bootstrapper.js`, `scripts/build_micro_wasm.sh`
    *   **Opcode pruning:** Remove unused opcodes from the JS Painter switch statement at build time based on the actual opcodes emitted by `Serializer` during compilation.
    *   **Component inlining:** If a component is used once and its HTML is below 512 bytes, skip emitting a separate `.yiseq` file and embed its bytecode directly into a JS base64 string loaded by the bootstrapper.
    *   **Bootstrapper minification:** Pass the bootstrapper through `terser` (or `esbuild --minify`) during `BuildMain#build`.
    *   **WASM compression:** Serve `.wasm` + `.yiseq` pre-compressed with Brotli (`Content-Encoding: br`) when the upstream supports it (already partially covered by `compress_yiseq` for `.yiseq` files — extend to `.wasm`).
*   **Acceptance Criteria:**
    *   The total compressed initial payload (`index.html` + embedded `bootstrapper.js`) stays under 14 kB.
    *   The lazy-loaded `.wasm` delivery is under 800 kB compressed (gzip or Brotli).
    *   Hot-reload in the Vite dev server still works after all minification passes.

---

## Appendix: Ruby Compiler Port Changes

The following table maps key constructs changed during the Crystal-to-Ruby port:

| Aspect | Crystal (Original Plan) | Ruby (`compiler_rb`) |
|--------|------------------------|----------------------|
| File extension | `.cr` | `.rb` |
| Type annotations | Built-in `struct` / `class` types | Sorbet `T::Sig` + `T::Struct` |
| Entrypoint | `compiler/src/entrypoints/building/transpiler.cr` | `compiler_rb/src/entrypoints/transpiler.rb` |
| Component generator | `compiler/src/webcomponents/component_generator.cr` | `compiler_rb/src/webcomponents/component_generator.rb` |
| Build orchestrator | Custom Crystal CLI | `compiler_rb/src/entrypoints/build_main.rb` + `BuilderMan` |
| Dev server | Custom HTTP server | `compiler_rb/src/tooling/dev_server.rb` (WEBrick-based) |
| Caching | Custom Crystal cache | `compiler_rb/src/caching/cache.rb` + `WarthogDB` |
| Runtime compilation | None (planned WASM) | `QuickJS::Opal::Builder` for current Opal transpilation |
| Data models | Crystal `struct` | Ruby `T::Struct` classes (e.g., `WebComponent`, `MochiComponent`) |
| File I/O | Crystal `File`, `Dir` | Ruby `File`, `Dir`, `FileUtils`, `Pathname` |
| CLI parsing | Crystal `OptionParser` | Ruby `OptionParser` from stdlib |
| JSON handling | Crystal `JSON` | Ruby `JSON` stdlib |
| Random IDs | Crystal `Random::Secure.hex` | Ruby `SecureRandom.hex` |
