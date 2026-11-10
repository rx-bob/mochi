# Implementing Attribute-Level Conditionals

## Problem Context
Currently, Mochi's conditional blocks (`{if condition}...{end}`) are designed as structural DOM nodes. When the compiler processes HTML, it replaces these blocks with HTML comment anchors (`<!--if-anchor-X-->`) and uses DOM insertion/removal to toggle them. 

When users attempt to use conditionals inline within an attribute (e.g., `<a class="nav-item {if @active}active{end}">`), the compiler mistakenly injects a comment anchor directly into the attribute string (`class="nav-item <!--if-anchor-X-->"`). The JS runtime's `NodeIterator` looks for comment nodes in the DOM tree, fails to find the one hidden inside the attribute string, and the conditional is silently ignored.

To support inline attribute conditionals without duplicating elements or dropping into JS, we must treat attribute-level conditionals as **Computed String Properties** rather than structural DOM nodes.

---

## Execution Plan: Epics & Stories

### Epic 1: Attribute Extraction & Preprocessing
*Detect `{if}` blocks inside attributes before they are processed as structural DOM elements, and extract them into discrete computed components.*

#### Story 1.1: Isolate Complex Attributes in HTML Preprocessor
**Goal:** Create a preprocessor phase that identifies HTML attributes containing block markers (`{if`, `{unless`) and strips them out before the standard `ConditionalProcessor` runs.
**Details:**
- Create an `AttributeConditionalExtractor` module.
- Parse the raw HTML string (using Lexbor or targeted Regex) to find all element attributes.
- If an attribute's value contains `{if` or `{unless`, flag it as a "Complex Attribute".
- Replace the original complex attribute value in the HTML with a unique binding token (e.g., `class="nav-item {if @active}active{end}"` becomes `class="{__mochi_attr_cond_0}"`).
- Store the mapping of these tokens to their original complex string values.
**Acceptance Criteria:**
- [ ] The `ConditionalProcessor` no longer sees `{if}` blocks that were inside attributes, preventing invalid `<!--if-anchor-->` generation.
- [ ] A clean mapping exists of `__mochi_attr_cond_X` to `"nav-item {if @active}active{end}"`.

#### Story 1.2: Generate Ruby Computed Methods for Attributes
**Goal:** Translate the extracted complex attribute strings into valid Ruby methods that evaluate to the final string.
**Details:**
- Extend the `ConditionalMethodGenerator` (or create an `AttributeMethodGenerator`) to process the mappings from Story 1.1.
- For each complex attribute string, generate a Ruby method that uses string concatenation and `if/else` logic.
- Example input: `"nav-item {if @active}active{end}"`
- Example output injected into the Ruby class:
  ```ruby
  def __mochi_attr_cond_0
    _res = "nav-item "
    if @active
      _res += "active"
    end
    _res
  end
  ```
**Acceptance Criteria:**
- [ ] Transpiled Ruby classes contain `__mochi_attr_cond_X` methods.
- [ ] The generated methods accurately reconstruct the intended string based on the component's state.
- [ ] Supports multiple `{if}` blocks within a single attribute (e.g., `class="{if @a}a{end} {if @b}b{end}"`).

### Epic 2: Transpiler & Reactivity Integration
*Wire the newly generated computed methods into the JavaScript rendering engine so the DOM updates when the underlying state changes.*

#### Story 2.1: Register Derived Attributes in Transpiler
**Goal:** Ensure the Transpiler recognizes `__mochi_attr_cond_X` as a reactive dependency so the JS generators know to track and update it.
**Details:**
- Since `__mochi_attr_cond_X` is a method and not an instance variable, the `InstanceVarAnalyzer` will naturally ignore it.
- Modify `transpile_component` in `transpiler.cr` to explicitly collect the IDs of all generated attribute conditionals.
- Pass this list of `derived_attributes` down to both `LegacyComponentGenerator` and `NewComponentGenerator`.
**Acceptance Criteria:**
- [ ] Generators receive the full array of derived attribute method names alongside the standard `reactables` array.

#### Story 2.2: JS Runtime Updates for Computed Attributes
**Goal:** Update the JS component generators to treat `{__mochi_attr_cond_X}` bindings as reactive expressions that trigger `setAttribute` on re-renders.
**Details:**
- **Legacy Engine (`LegacyComponentGenerator.cr`):** 
  - Update the `_attrCache` initialization to scan for and cache elements containing `{__mochi_attr_cond_X}` markers.
  - In the `render()` method, add a loop that evaluates `this.rubyComp.$__mochi_attr_cond_X()` and applies the result to the cached elements using `setAttribute`.
- **New Engine (`NewComponentGenerator.cr`):**
  - Add logic in `updateDerived()` to execute the method and update the corresponding attribute node reference.
**Acceptance Criteria:**
- [ ] Modifying `@active` in Ruby automatically updates the `class` attribute on the DOM element in the browser.
- [ ] Both Legacy and New rendering engines support the feature.

### Epic 3: Hash-Based Attribute Binding (`class={{...}}`)
*Provide an idiomatic, Ruby-native alternative for dynamic attribute construction using Hashes.*

#### Story 3.1: Support Ruby Hashes in Attribute Bindings
**Goal:** Allow developers to pass a Ruby Hash directly into a Mochi binding for an attribute (like `class`), keeping only the keys where the value evaluates to true.
**Details:**
- In Ruby on Rails (ActionView/ViewComponent), passing a Hash to dynamically build HTML attributes is the standard convention. Mochi should adopt this for bindings like `class={{...}}`.
- Update the compiler/runtime to detect when an attribute binding evaluates to a Ruby Hash.
- Serialize the Hash into a space-separated string by selecting keys with truthy values (e.g., `hash.select { |k, v| v }.keys.join(" ")`).
- Support both standard and newer Ruby hash syntaxes:
  - `<a class={{ "nav-item" => true, "active" => @active }}>Link</a>`
  - `<a class={{ "nav-item": true, "active": @active }}>Link</a>`
**Acceptance Criteria:**
- [ ] Hashes passed to attribute bindings correctly evaluate and serialize into space-separated string values.
- [ ] Only keys with truthy values are included in the final rendered attribute.
- [ ] The feature smoothly integrates with other attribute binding logic.