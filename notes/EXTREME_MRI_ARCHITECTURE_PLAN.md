# Mochi: The "Extreme MRI" Architecture Plan (Comprehensive)

This document outlines the extreme performance architecture for Mochi, delivering **100% MRI Ruby in the browser** while hitting the **14kB initial payload limit** and bypassing standard WebAssembly-to-JS interop bottlenecks.

This is a massive engineering undertaking. It requires a custom fork of MRI Ruby, deep C-level modifications, a custom WebAssembly build pipeline, and a highly optimized memory-sharing architecture. 

---

## Epic 1: The 14kB Base - Hollow Shells & Server-Side Generation
**Goal:** Guarantee instant page loads by rendering the initial HTML on the server. The first network request must contain the fully styled UI, strictly under 14kB compressed.

### Story 1.1: Static Component HTML Generator
*   **Details:** The Mochi Crystal compiler must execute or evaluate the Ruby component's `#html` and `#css` definitions at build time.
*   **Technical Details:**
    *   **Target:** `compiler/src/webcomponents/component_generator.cr`
    *   Modify the generator to output standard HTML strings where the internal template of the component is rendered as Light DOM or Declarative Shadow DOM.
    *   Strip out dynamic bindings (`{count}`) and replace them with their initial `#initialize` values.
*   **Acceptance Criteria:**
    *   The build outputs an `index.html` with fully expanded Web Components.
    *   Components contain `data-mochi-hydrate="true"` and `data-mochi-state="{...}"` (JSON serialized initial state).

### Story 1.2: The Micro-Bootstrapper (Intersection Observer)
*   **Details:** A highly optimized (~1-2kB) JavaScript file that defers loading the WASM engine until a component is visible.
*   **Technical Details:**
    *   **Target:** `packages/mochi-runtime/bootstrapper.js`
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
    *   **Target:** `compiler/src/entrypoints/building/transpiler.cr`
    *   Bundle a CLI tool (e.g., `wasmtime`) with the Mochi compiler.
    *   During transpilation, execute: `wasmtime run mochi-ruby-micro.wasm -- dump_iseq counter.rb > counter.yiseq`.
    *   The WASM Ruby instance runs a script that calls `RubyVM::InstructionSequence.compile_file('counter.rb').to_binary` and writes to `STDOUT`.
*   **Acceptance Criteria:**
    *   The build pipeline successfully outputs 32-bit, WASM-compatible `.yiseq` binary files regardless of the host OS (Mac/Linux/Windows).

### Story 2.2: Vite Plugin Integration for Bytecode Assets
*   **Details:** Integrate the `.yiseq` generation into the modern Vite build graph.
*   **Technical Details:**
    *   **Target:** `packages/vite-plugin-mochi/index.ts`
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

---

## Epic 4: The Shared Memory DOM Bridge (Extreme Rendering)
**Goal:** Bypass WASM-to-JS serialization entirely. Ruby will mutate a Virtual DOM and write binary "diff opcodes" directly to a shared memory buffer. JS will read this buffer natively and paint the DOM.

### Story 4.1: The Ruby Virtual DOM
*   **Details:** Implement a lightweight DOM representation strictly in Ruby.
*   **Technical Details:**
    *   **Target:** `packages/mochi-runtime/lib/virtual_node.rb`
    *   Create classes to represent Elements, Text Nodes, and Attributes.
    *   Implement a diffing algorithm (similar to React/Preact) that compares the "old" VDOM tree to the "new" VDOM tree after a state change.
*   **Acceptance Criteria:**
    *   The diffing algorithm successfully outputs a list of logical mutations (e.g., "Change text of node 5", "Add class 'active' to node 2").

### Story 4.2: C-Extension for Memory Buffer Export
*   **Details:** Ruby needs a way to write these diffs to a specific memory address that JS can read.
*   **Technical Details:**
    *   **Target:** `ext/mochi_bridge/mochi_bridge.c` (New C extension compiled into the custom WASM).
    *   Allocate a static memory buffer (e.g., 64kB) `uint8_t render_buffer[65536]`.
    *   Expose C functions to Ruby: `MochiBridge.write_opcode(type, node_id, ptr)`.
    *   Export the memory offset of `render_buffer` to the WASM exports so JS knows exactly where to look.
*   **Acceptance Criteria:**
    *   Ruby can call `MochiBridge.write_opcode` and the bytes appear at the correct offset in the JS `WebAssembly.Memory` object.

### Story 4.3: The JS Painter (Memory Decoder)
*   **Details:** The JS side of the bridge. It reads the raw bytes and touches the real DOM.
*   **Technical Details:**
    *   **Target:** `packages/mochi-runtime/painter.js`
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
    *   **Target:** `packages/mochi-runtime/event_bridge.js`
    *   Set up a global event listener on `document`.
    *   When an event fires on a component, write an "Event Opcode" into an "Event Buffer" in WASM memory.
    *   Structure: `[Event Type (1 byte), Target Node ID (4 bytes), Data Payload Pointer (4 bytes)]`.
    *   Call an exported WASM function: `mochi_process_events()`.
*   **Acceptance Criteria:**
    *   Clicks successfully trigger the WASM exported function with data available in the memory buffer.

### Story 5.2: Ruby Event Router & Execution Tick
*   **Details:** Ruby must read the event buffer, trigger the correct component method, and flush the VDOM diff.
*   **Technical Details:**
    *   **Target:** `packages/mochi-runtime/lib/event_loop.rb`
    *   Implement `Mochi::EventLoop.tick`.
    *   Read the Event Buffer via `MochiBridge.read_events`.
    *   Find the target component instance based on Node ID.
    *   Call the appropriate method (e.g., `increment`).
    *   Run the VDOM diffing algorithm (Story 4.1).
    *   Write the diff to the Render Buffer (Story 4.2).
    *   Return control to JS.
*   **Acceptance Criteria:**
    *   Clicking "Increment" in the browser results in the Ruby `@count` increasing and the DOM updating in a single synchronous cycle.

---

## Epic 6: State Hydration & Memory Reconstruction
**Goal:** Seamlessly transition from the server-rendered HTML to the WASM-managed Virtual DOM.

### Story 6.1: VDOM Reconstruction from DOM
*   **Details:** When a component boots, it must build its initial VDOM tree to match the existing HTML, otherwise the first diff will destroy and recreate the whole component.
*   **Technical Details:**
    *   **Target:** `packages/mochi-runtime/lib/component.rb`
    *   During `#initialize`, read `data-mochi-state`.
    *   Execute the component's `#html` method internally to generate the expected VDOM.
    *   Crucially: The JS Painter must traverse the *existing* DOM and assign sequential `Node IDs` to the DOM elements that exactly match the `Node IDs` generated by Ruby's VDOM builder.
*   **Acceptance Criteria:**
    *   When hydration completes, the first VDOM diff produces zero opcodes (because the VDOM perfectly matches the server-rendered HTML).
    *   Subsequent clicks correctly mutate the existing elements without recreating them.