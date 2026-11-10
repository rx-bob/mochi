# Mochi Next-Gen Rendering Engine: Compiled Fine-Grained Reactivity

## Architecture Decision Record (ADR)

**Title:** Compiled Fine-Grained Reactivity (The "Direct-DOM" Approach)
**Status:** PROPOSED (v2 - Aggressive Optimization)
**Date:** 2026-02-21
**Author:** Gemini CLI

### Context
We previously considered a generic "Signal-Based" runtime (like SolidJS). While fast, generic signals still incur runtime overhead:
1.  **Allocation:** Creating closures/objects for every reactive value and effect.
2.  **Discovery:** Runtime dependency tracking (reading a signal pushes it to a stack).
3.  **Indirection:** Iterating through subscriber sets.

To achieve the "Performance Crown," we must eliminate these overheads for the most common use case: local component state.

### Decision
We will implement a **Hybrid Compiled/Runtime Engine**.

1.  **Primary Mechanism (Local State):** **Direct-DOM Compilation**.
    - The compiler analyzes `def html` and `initialize`.
    - Instead of generic `Signal` objects, we generate **Reactive Setters** on the component class.
    - **Zero Allocation:** No signal objects, no subscription sets for local variables.
    - **Direct Updates:** `@count = 1` compiles to `this.count = 1; this._dom_text_0.data = 1;`.

2.  **Secondary Mechanism (Shared/Complex State):** **Runtime Signals**.
    - For state shared between components or complex computed values we cannot statically analyze, we fall back to a lightweight Signal runtime.

3.  **DOM Creation:** **Cloning & Pre-compiled Walkers**.
    - We stick to `cloneNode(true)` as the fastest instantiation method.
    - We use pre-calculated integer paths (e.g., `[0, 3, 1]` for `child[0].child[3].child[1]`) to locate nodes, avoiding string parsing (`querySelector`).

### Performance Hypothesis
- **vs Virtual DOM:** Orders of magnitude faster (O(1) updates vs O(N) diffing).
- **vs Generic Signals:** Faster startup (less garbage collection/allocation) and faster updates (direct function calls vs set iteration).

---

## Technical Design: "The Bare Metal"

### 1. The Component Structure (Compiled Output)

**Input (Ruby):**
```ruby
class Counter
  @count = 0
  def html; "<span>{@count}</span>"; end
  def inc; @count += 1; end
end
```

**Output (Optimized JS):**
```javascript
class Counter extends MochiComponent {
  mount(target) {
    // 1. Clone & Cache
    // Template: <template id="t1"><span> </span></template>
    const root = getTemplate('t1').cloneNode(true);
    
    // 2. Walk & Bind (Hardcoded Paths)
    // Path: First Child (The Span) -> First Child (The Text Node)
    this._dom_count = root.firstChild.firstChild; 
    
    // 3. Init State (Direct Assignment)
    this._count = 0;
    this._dom_count.data = 0; 
    
    target.appendChild(root);
  }

  // 4. Reactive Setter (The "Signal")
  // The compiler identified that @count is used in 1 place.
  get count() { return this._count; }
  set count(val) {
    if (val === this._count) return; // Dirty Check
    this._count = val;
    this._dom_count.data = val; // Direct Update!
  }

  inc() {
    this.count = this.count + 1; // Triggers setter
  }
}
```

### 2. Handling Complex Cases (The Runtime Fallback)
When static analysis fails (e.g., passing a variable to a helper), we wrap it in a `Signal`.

```javascript
// Runtime Helper
class Signal {
  constructor(val) { this.v = val; this.subs = []; }
  get() { if (Target) Target.deps.push(this); return this.v; }
  set(v) { this.v = v; for(let s of this.subs) s.update(); }
}
```

### 3. List Reconciliation (`<mochi-each>`)
We cannot use setters for lists. We need a specialized **Block Reconciler**.
- **Strategy:** "Keyed Diffing" with a cursor.
- **Optimization:** Detect "Append Only" patterns (common in logs/feeds) and bypass diffing.

---

## Execution Plan: Epics & Stories

### Epic 1: The Crystal Template Analyzer (Static Analysis)
*The compiler's "Brain". It must understand the relationship between Ruby state and HTML structure before any code is generated.*

#### Story 1.1: AST Analysis for Instance Variables
**Goal:** Identify all instance variables (e.g., `@count`, `@user`) used within the component and classify them as "Reactive State".
**Details:**
- Parse the Ruby class body using `TreeSitter::Ruby`.
- Walk the AST to find assignments to instance variables (writers) and reads (readers).
- Flag variables used in `def html` as "Bound State".
**Acceptance Criteria:**
- [ ] Compiler outputs a list of detected instance variables for a given component.
- [ ] Variables are correctly categorized: "State" (mutated), "Constant" (never changed), or "Derived" (only read).
- [ ] Correctly handles `attr_accessor` and manual `@var = val` assignments.

#### Story 1.2: HTML Binding Extraction & Path Generation
**Goal:** Parse the `def html` string, extract dynamic bindings (`{...}`), and generate a precise DOM path to them.
**Details:**
- Use `Lexbor` to parse the HTML string.
- Traverse the DOM tree.
- For every Text Node containing `{...}`:
    - Replace content with a placeholder (empty string or space).
    - Record the "Path": a list of child indices (e.g., `[0, 1, 3]` -> root.children[0].children[1].children[3]).
- For every Element with attributes containing `{...}`:
    - Remove the dynamic attribute from the static HTML.
    - Record the "Path" to the element and the specific attribute name.
**Acceptance Criteria:**
- [ ] `<div><span>{@count}</span></div>` results in static HTML `<div><span></span></div>` and a Path `[0, 0]` for the text node.
- [ ] `<button class={@active}>` results in static HTML `<button></button>` and Path `[0]` + Attribute `class`.
- [ ] Complex paths (deep nesting) are correctly calculated.

#### Story 1.3: Dependency Graph Generation
**Goal:** Map every "Bound State" variable to the specific DOM updates it triggers.
**Details:**
- Create a mapping: `Variable -> [List of DOM Operations]`.
- A DOM Operation is defined by: `(Path, Type: [Text|Attribute], Name?)`.
**Acceptance Criteria:**
- [ ] Modifying `@count` is linked to updating the text node at Path `[0, 0]`.
- [ ] Modifying `@active` is linked to updating the `class` attribute at Path `[0]`.
- [ ] A single variable used in multiple places maps to *all* relevant DOM updates.

### Epic 2: The Code Generator (Transpiler)
*The compiler's "Muscle". transforming the analysis into highly optimized JavaScript.*

#### Story 2.1: Template Registry & Cloning Strategy
**Goal:** Efficiently create DOM nodes. Generate a static `<template>` tag once per component class, not per instance.
**Details:**
- Generate a global JS object `_mochi_templates`.
- In the component's static initialization, inject the stripped HTML into a `<template>` tag.
- In `mount()`, use `template.content.cloneNode(true)`.
**Acceptance Criteria:**
- [ ] Generated JS includes a static HTML string.
- [ ] `mount()` creates a fresh DOM tree from the template.
- [ ] Browser parsing (innerHTML) happens only *once* per component class, not per instance.

#### Story 2.2: Reactive Property (Setter) Generation
**Goal:** Create the "Zero-Overhead" reactivity. Compile ruby variable assignments into JS setters that update the DOM directly.
**Details:**
- For every "Bound State" variable (from Story 1.1), generate a JS `get` and `set` method on the class.
- The `set` method must:
    1. Check if value changed (Dirty Check).
    2. Update the backing field (`this._count = val`).
    3. Execute all mapped DOM operations (from Story 1.3).
**Acceptance Criteria:**
- [ ] Ruby code `@count = 5` compiles to `this.count = 5` in JS.
- [ ] The generated JS setter updates `this._dom_node_X.data` immediately.
- [ ] No generic "Signal" objects are created for these simple variables.

#### Story 2.3: Efficient DOM Walker Generation
**Goal:** Locate the dynamic nodes in the cloned DOM tree without using slow `querySelector`.
**Details:**
- Generate a `_walk()` method or inline code in `mount()`.
- Use the Paths (from Story 1.2) to traverse `firstChild` and `nextSibling`.
- Assign references to private properties: `this._dom_text_count = root.firstChild.nextSibling...`.
**Acceptance Criteria:**
- [ ] Generated code uses only direct property access (`firstChild`, `nextSibling`), no string parsing.
- [ ] All dynamic nodes are correctly assigned to `this._dom_X` properties before the first render.

### Epic 3: The Runtime Kernel (Reactivity Fallback)
*The "Safety Net" for complex state that cannot be statically analyzed.*

#### Story 3.1: Minimal Signal Implementation
**Goal:** Provide a lightweight Signal library for shared state, stores, or complex computed values.
**Details:**
- Implement `createSignal(initialValue)` -> `[getter, setter]`.
- Implement `createEffect(fn)`.
- Use a global context stack to track dependencies.
**Acceptance Criteria:**
- [ ] `signal()` returns a reactive getter/setter.
- [ ] `effect()` runs immediately and re-runs when dependencies change.
- [ ] Nested effects are handled correctly.
- [ ] Size budget: < 1KB (minified).

#### Story 3.2: The `MochiComponent` Base Class
**Goal:** The common runtime foundation for all components.
**Details:**
- `constructor`: Initialize basic state.
- `mount(parent)`: Abstract method called by users.
- `unmount()`: Cleanup event listeners and effects.
**Acceptance Criteria:**
- [ ] Base class handles lifecycle correctly.
- [ ] Provides utility for "cleanup" (e.g., when an `if` block removes a component).

### Epic 4: Control Flow (Conditionals & Lists)
*Handling dynamic structure, not just dynamic values.*

#### Story 4.1: `<mochi-if>` Anchor System & Compilation
**Goal:** Compile `if` blocks into efficient DOM swaps using Comment Anchors.
**Details:**
- Compiler: Replace `<mochi-if>` with a Comment Node `<!--if-anchor-->`.
- Generator: Create a `createEffect` that wraps the condition.
- Runtime:
    - If true: Insert the Fragment (cloned from template) after the anchor.
    - If false: Remove the Fragment (but keep the anchor).
**Acceptance Criteria:**
- [ ] `<mochi-if>` is removed from the static HTML.
- [ ] Toggling the condition adds/removes elements from the DOM.
- [ ] Nested `if` blocks work correctly.

#### Story 4.2: `<mochi-each>` Reconciliation Algorithm (LIS)
**Goal:** Update lists with minimal DOM movement using the Longest Increasing Subsequence algorithm.
**Details:**
- Compiler: Replace `<mochi-each>` with a Comment Node.
- Runtime:
    - Track the array of data.
    - On update, diff the new array against the old.
    - Identify items to Keep, Move, Insert, or Delete.
    - Apply changes to the DOM relative to the anchor.
**Acceptance Criteria:**
- [ ] Reordering an array moves DOM nodes, doesn't recreate them.
- [ ] Appending to an array only appends a DOM node.
- [ ] Performance is O(N) or better for common operations.

### Epic 5: The "Big Switch" (Migration)
*Replacing the engine while the car is driving.*

#### Story 5.1: Deprecate `WebComponentGenerator`
**Goal:** Phase out the old string-replacement based generator.
**Details:**
- Rename `WebComponentGenerator` to `LegacyComponentGenerator`.
- Ensure the build system still works (but maybe warns) for old components.
- Introduce a flag `--experimental-new-engine` to the CLI.
**Acceptance Criteria:**
- [ ] `mochi build` still works.
- [ ] `mochi build --experimental-new-engine` triggers the new code path (Story 5.2).

#### Story 5.2: Wire up `NewComponentGenerator`
**Goal:** Connect the new pipeline (Epic 1 & 2) to the main `mochi` compiler command.
**Details:**
- Create `NewComponentGenerator` class that orchestrates the Analyzer, DependencyGraph, and CodeGenerator.
- Replace the call site in `mochi.cr` to use this new generator when the flag is present (or by default if confident).
- Verify the output JS file contains the new class structure.
**Acceptance Criteria:**
- [ ] Running the compiler produces valid JS files using the `MochiComponent` base class.
- [ ] The generated JS has no traces of the old `innerHTML` replacement logic.

#### Story 5.3: Runtime Library Integration
**Goal:** Ensure `mochi.js` (the runtime bundle) includes the new `MochiComponent` base class and Signal library.
**Details:**
- Add the new TS/JS runtime files to the `compiler/src/js/runtime` (or similar) folder.
- Ensure they are bundled into the final `mochi.js` shipped with the app.
**Acceptance Criteria:**
- [ ] The browser can load `mochi.js` and find `class MochiComponent`.
- [ ] `createSignal` is available globally or via module import.

### Epic 6: Benchmark & Validation
*Proving we have the crown.*

#### Story 6.1: JS Framework Benchmark Implementation
**Goal:** Implement the standard "Krausest" benchmark in Mochi.
**Details:**
- Implement "Create 1,000 rows".
- Implement "Replace all rows".
- Implement "Partial Update" (update every 10th row).
- Implement "Select Row".
- Implement "Swap Rows".
- Implement "Remove Row".
**Acceptance Criteria:**
- [ ] Benchmark runs without errors.
- [ ] Performance metrics (FPS, Memory) are collected.
- [ ] Mochi outperforms the previous version significantly.
- [ ] Mochi is competitive with SolidJS/Svelte.
