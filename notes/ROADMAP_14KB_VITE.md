# Mochi Roadmap: The 14kB Resumable Vite Architecture

This document breaks down the implementation of the new Mochi architecture (Single-File Compilation, Vite Integration, and 14kB Resumable Hydration) into actionable Epics and User Stories, specifically detailing the files and methods that need to be modified in the Mochi codebase.

---

## Epic 1: The Core - Single-File Compilation Model
**Goal:** Shift the Mochi compiler from a monolithic `bundle.js` generator to an intelligent ES Module compiler that compiles one `.rb` file into one `.js` file, extracting dependencies along the way.

### Story 1.1: Add `mochi compile-file` CLI Command
* **Description:** As a build tool, I need a CLI command that takes a single `.rb` file and outputs the transpiled code to `stdout`.
* **Technical Details:**
  * **File:** `compiler/src/mochi.cr`
  * **Change:** Add a new command `p.on("compile-file", "Compile a single ruby file to stdout") do ... end`. Set a boolean `is_single_file_compile = true` and read `ARGV[0]`.
  * **File:** `compiler/src/entrypoints/building/transpiler.cr`
  * **Change:** Add a new method `def transpile_single_file(file_path : String)`. It should read the file, run `RubyUnderstander`, call `transpile_component`, and print the resulting JS directly to `STDOUT` (bypassing the global file writing loops).

### Story 1.2: Extract Ruby `require` Statements via AST
* **Description:** As the Mochi compiler, I need to know what other files a Ruby component depends on so I can pass that information to modern JS bundlers.
* **Technical Details:**
  * **File:** `compiler/src/ruby/ruby_understander.cr`
  * **Change:** Add a new class method `def self.extract_requires(rb_file : String) : Array(String)`.
  * **Implementation:** Utilize the TreeSitter parser (similar to `extract_method_bodies`) to find `call` nodes where the method name is `require` or `require_relative`, and extract the string argument. Return an array of these strings.

### Story 1.3: Inject ES Module `import` Headers
* **Description:** As a Vite-compatible loader, Mochi must map Ruby dependencies to JS imports.
* **Technical Details:**
  * **File:** `compiler/src/entrypoints/building/transpiler.cr`
  * **Change:** Inside `transpile_single_file` (from Story 1.1) or `transpile_component`, call `RubyUnderstander.extract_requires`.
  * **Implementation:** For each required path, prepend a JS line to the final output string: `import "#{req}.rb";` (or omit `.rb` if it's a gem). 
  * Ensure the Opal compiled string for the file still correctly runs: `Opal.modules["#{filename}"] = ...`.

### Story 1.4: Refactor Component Generator for ESM & HMR
* **Description:** As a modern framework, the output Web Component JS must be an ES Module and be safe for Hot Module Replacement.
* **Technical Details:**
  * **File:** `compiler/src/webcomponents/component_generator.cr`
  * **Change:** Modify the `generate` method, specifically how it builds the `js` string.
  * **Implementation:** 
    * Add ESM Imports: `import { Opal, MochiComponent } from 'mochi-runtime';` at the top.
    * Wrap registration: Instead of `customElements.define('#{tag_name}', ...)`, output `if (!customElements.get('#{tag_name}')) { customElements.define('#{tag_name}', #{mochi_cmp_name}WebComp); }`.
    * Add export: Append `export default #{mochi_cmp_name}WebComp;` to the end of the JS string.

### Story 1.5: Extract `mochi-runtime` Package
* **Description:** As a Vite plugin, I need the Opal core and Mochi base classes available as a standard NPM/JS dependency, rather than bundled by the Mochi CLI every time.
* **Technical Details:**
  * **Files:** Create a new directory structure `packages/mochi-runtime/`.
  * **Change:** Move the logic from `OpalRuntimeGenerator` (`compiler/src/opal/opal_runtime_generator.cr`) and `batteries/core_battery.cr` to output their contents statically into this NPM package directory.
  * **Implementation:** Create a `package.json` for `mochi-runtime`. Expose the base `MochiComponent` class and the initialized `Opal` object as standard ES module exports.

---

## Epic 2: The Modern Dev Experience - Vite Plugin
**Goal:** Create `vite-plugin-mochi` so developers can use Vite's ecosystem, dev server, and CSS pipeline seamlessly with Mochi Ruby files.

### Story 2.1: Scaffold `vite-plugin-mochi`
* **Description:** As a frontend developer, I want to add Mochi to a Vite project via a simple Vite plugin.
* **Technical Details:**
  * **Files:** Create a new directory `packages/vite-plugin-mochi/`.
  * **Implementation:** Initialize a Node.js project (`package.json`, `index.ts`). Export a standard Vite plugin object with a `name: 'vite-plugin-mochi'` and a `enforce: 'pre'` flag. Add a regex filter to only process files ending in `\.rb$`.

### Story 2.2: Implement the `transform` Hook
* **Description:** As the Vite plugin, I need to call the Mochi CLI to transform Ruby source code into JS on the fly.
* **Technical Details:**
  * **File:** `packages/vite-plugin-mochi/index.ts`
  * **Implementation:** Inside the `transform(code, id)` hook, check if `id` ends in `.rb`. If so, use Node's `child_process.execSync` or `spawn` to execute `mochi compile-file "#{id}"`. Capture `stdout` as the compiled JS string and return it as the transformed code for Vite.

### Story 2.3: Ruby Gem Dependency Resolution
* **Description:** As a developer using gems, when I `require "faker"`, the Vite plugin needs to find it.
* **Technical Details:**
  * **File:** `packages/vite-plugin-mochi/index.ts`
  * **Implementation:** Implement the Vite `resolveId(source, importer)` hook. If `source` comes from a `.rb` file and doesn't look like a relative path or an NPM package, attempt to run `bundle show #{source}` via `child_process`. Return the absolute path to the gem's `.rb` file so Vite can process it.

---

## Epic 3: The 14kB Speed - Static "Hollow Shell" Generation
**Goal:** Generate the initial HTML markup for components at build time so the browser paints instantly without waiting for Ruby to load.

### Story 3.1: Server-Side Render (SSR) the Component HTML/CSS
* **Description:** As the Mochi compiler, I need to extract the exact HTML and CSS string from the Ruby methods to generate the static shell.
* **Technical Details:**
  * **File:** `compiler/src/webcomponents/component_generator.cr`
  * **Change:** Add a new method `generate_static_html(tag_name, html, css)` that returns the raw markup.
  * **File:** `compiler/src/entrypoints/building/build_main.cr`
  * **Change:** Create a routine that loops over the `components` array and constructs a static `index.html` where custom elements have their inner HTML (from `#html` and `#css`) statically injected.

### Story 3.2: Inject Initial State Metadata
* **Description:** As a hydrating framework, the client needs to know what the initial state was without running the Ruby constructor again.
* **Technical Details:**
  * **File:** `compiler/src/entrypoints/building/build_main.cr`
  * **Implementation:** When generating the static HTML tags, find the initial values of variables set in `#initialize` (this may require partial evaluation or AST parsing of the constructor via `RubyUnderstander`). Inject these as JSON: `<my-counter data-mochi-state='{"count": 0}'>`.

---

## Epic 4: Lazy Hydration & The Bootstrapper
**Goal:** Only load and execute the Ruby runtime for components that are currently visible on the user's screen.

### Story 4.1: Develop the 1kB Bootstrapper
* **Description:** As a user on a slow connection, I want the minimum JS necessary to track what I'm looking at.
* **Technical Details:**
  * **File:** `packages/mochi-runtime/bootstrapper.js`
  * **Implementation:** Write a small script using `IntersectionObserver`. Query the DOM for `[data-mochi-hydrate]` or `<my-*>` tags.

### Story 4.2: Dynamic Import of Component Logic
* **Description:** As the bootstrapper, when a component is visible, I must fetch its specific logic and the runtime.
* **Technical Details:**
  * **File:** `packages/mochi-runtime/bootstrapper.js`
  * **Implementation:** Inside the intersection callback, write: `import(\`./components/${element.tagName.toLowerCase()}.js\`).then(mod => hydrate(element, mod.default))`. 

### Story 4.3: The Hydration Bridge (Attaching logic to existing DOM)
* **Description:** As a loaded Mochi component, I need to "wake up" the existing HTML rather than destroying it and re-rendering.
* **Technical Details:**
  * **File:** `compiler/src/webcomponents/component_generator.cr`
  * **Change:** Modify the `mount(target)` method in the generated JS class. 
  * **Implementation:** Instead of `target.appendChild(r)` (cloning the template blindly), it should check `if (target.innerHTML.trim() !== '')`. If content already exists, it skips cloning, reads `target.dataset.mochiState` to set initial variables on `this.rubyComp`, maps the `dom_refs` to existing nodes, and simply attaches the global `this.shadow.addEventListener` logic.