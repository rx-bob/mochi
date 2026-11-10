# Context-Aware Event Handlers in Mochi

## Problem Context
Currently, Mochi event handlers (like `onclick={method}`) call the corresponding Ruby method with **no arguments**, or at best, the raw javascript `Event` object for `onchange`. 

For any list-based UI (e.g., clicking a specific "Delete" button in a list of 10 items), this design forces developers to either:
1. Create a separate component/method for every single item.
2. Bail out to raw JavaScript.

We need a Ruby-esque solution to pass context (like the loop's current item, or a data attribute from the element) directly into the Ruby event handler. 

---

## The Vision: Ruby-Esque Context Passing

In Ruby on Rails and forms, context is often passed implicitly via the params hash, or explicitly via method arguments. 
For Mochi, we want developers to easily pass arguments to their methods from the view. 

**Option 1: Explicit Argument Passing (Syntactic Sugar)**
```html
<button onclick="{delete_item(item.id)}">Delete</button>
```

**Option 2: Implicit DOM Data Extraction (`dataset`)**
Often, a button already holds the context in `data-*` attributes. We can automatically pass the element's `dataset` to the Ruby method if the method accepts an argument.
```html
<button data-id="{item.id}" data-role="admin" onclick="{delete_item}">Delete</button>
```
```ruby
# Ruby side receives the DOM dataset as a Ruby Hash or NamedTuple
def delete_item(data)
  puts "Deleting user #{data["id"]} with role #{data["role"]}"
end
```

Option 1 provides ultimate flexibility and feels very Ruby/ViewComponent. Option 2 is a great fallback that embraces the DOM. We should aim to support **Explicit Argument Passing**.

---

## Execution Plan: Epics & Stories

### Epic 1: Parser Support for Handler Arguments
*Upgrade the system to recognize `onclick="{method(arg1, arg2)}"` instead of only `onclick="{method}"`.*

#### Story 1.1: Enhance Event Binding Regex / Parsing
**Goal:** Modify the JS Generators (`LegacyComponentGenerator` & `NewComponentGenerator`) so their Event Delegation listeners can parse method arguments from standard `on*` attribute strings.
**Details:**
- Currently, the JS generators do: `getAttribute('onclick').replace(/[{}]/g, '')` to get the method name.
- We need to parse the string to separate the method name from the arguments: `delete_item(item.id)` -> Method: `delete_item`, Args: `['item.id']`.
- Note: The arguments in the string (e.g. `item.id`) are currently evaluated in the JS context. In Mochi's DOM templates, `item` is an iteration variable provided by the JS engine during `_substituteItemVars` or template cloning. 
**Acceptance Criteria:**
- [ ] The event delegation logic accurately extracts the method name independently from the argument string.
- [ ] The system gracefully falls back to no-argument parsing if no parentheses are present.

#### Story 1.2: Resolve JS Variables to Values at Event Time
**Goal:** Ensure that the arguments passed to the Ruby method are evaluated correctly in JS before crossing the bridge to Ruby.
**Details:**
- When `delete_item({user.id})` or `delete_item(123)` is clicked, the JS event listener must evaluate the arguments.
- If the argument is a primitive (like `123` or `'hello'`), it's straight forward.
- If the argument is a dynamic variable from an `{each}` block (like `item.id`), Mochi needs to ensure this value is accessible at click time.
- **Implementation Path:** The easiest JS-native way to achieve this is actually Option 2 under the hood. Have the compiler transform `onclick="{delete_item(item.id)}"` into `<button data-mochi-arg-0="{item.id}" onclick="{delete_item}">`. Then, the global click listener reads `dataset.mochiArg0`, converts it to the proper type, and passes it to the Ruby method.
**Acceptance Criteria:**
- [ ] The compiler transpiles inline method arguments into `data-mochi-arg-*` attributes on the element.
- [ ] The JS click listener reads these sequential `data-mochi-arg-*` attributes, parses them (handling numbers vs strings), and prepares an array of arguments to pass to `this.rubyComp['$'+action](...args)`.

#### Story 1.3: Clean Up Legacy `on:click` Syntax
**Goal:** Remove all old regex parsing and placeholder replacement logic that supported the old `on:click` and `on:change` syntax.
**Details:**
- The JS generators currently rely on `WebComponentPlaceholder::OnClick.string_value` and manual `.replace()` logic converting placeholders back into `[on\\:click]` CSS selectors. 
- With standard HTML attribute names (`onclick` and `onchange`), this workaround is no longer necessary. 
- Clean up `legacy_component_generator.cr`, `new_component_generator.cr`, and any compiler placeholders referring to the old `:click` syntax.
**Acceptance Criteria:**
- [ ] The old string replace logic for `[on\\:click]` and `input[on\\:change]` is completely removed.
- [ ] Event delegation cleanly queries for standard HTML `[onclick]` and `[onchange]` attributes.

### Epic 2: Ruby Runtime Method Bridging
*Ensure the Opal Ruby runtime accepts the arguments passed from the JS event delegation and routes them to the correct Ruby component method.*

#### Story 2.1: Update JS-to-Ruby Call Logic
**Goal:** Modify the JS template generators to use `apply()` or spread syntax when calling the Ruby method.
**Details:**
- In `LegacyComponentGenerator.cr` and `NewComponentGenerator.cr`, update the event delegation block:
  ```javascript
  // Old
  this.rubyComp['$'+action]();
  
  // New
  let args = extractMochiArgs(target); // reads data-mochi-arg-*
  this.rubyComp['$'+action](...args);
  ```
**Acceptance Criteria:**
- [ ] Both Legacy and New rendering engines successfully pass dynamic arrays of arguments to the underlying Opal `$method` call.

#### Story 2.2: Implement `$event` and `$element` magical variables (Bonus)
**Goal:** Give Ruby handlers access to the raw JS Event or Element context if they explicitly ask for it.
**Details:**
- If the user writes `onclick="{handle_click($event, item.id)}"`, the transpiler should recognize `$event` as a magical keyword.
- Instead of writing `$event` to a `data-` attribute, the JS compiler understands to pass the actual `event` object in that position of the argument array.
**Acceptance Criteria:**
- [ ] Passing `$event` inside the parenthesis passes the raw JS MouseEvent to the Ruby backend.

### Epic 3: Support Raw DOM `dataset` as a Hash (Alternative/Complement)
*Allow developers who prefer standard HTML to just read `data-*` attributes directly.*

#### Story 3.1: Pass Dataset to Ruby
**Goal:** If a developer defines a handler as `def handle_click(dataset)`, automatically pass the element's dataset as a hash or Opal struct.
**Details:**
- In the JS event listener, before calling `rubyComp['$'+action]()`, we can inspect the method's arity (if Opal allows, or just always pass it).
- Passing `target.dataset` (converted to an Opal Hash) as the implicit final argument if it's not explicitly requested via Option 1.
**Acceptance Criteria:**
- [ ] Developers can write `<button data-id="12" onclick="{delete}">` and `def delete(dataset)` inside Ruby to access `dataset["id"]`.
- [ ] Plays nicely alongside explicit arguments.

### Epic 4: Documentation
*Provide clear documentation on how these context-aware event handlers work.*

#### Story 4.1: Write `notes/docs/CLICK_HANDLERS.md`
**Goal:** Create a comprehensive guide explaining the new event handler syntax, how arguments are evaluated and passed, and how to use the raw `dataset` fallback.
**Details:**
- Write the documentation explaining the difference between the old `on:click={method}` (which passed no arguments) and the new `onclick={method(arg1, arg2)}`.
- Explain how variables from `{each}` blocks are captured.
- Explain the `$event` keyword.
- Explain the `dataset` hash fallback.
**Acceptance Criteria:**
- [ ] A new file `notes/docs/CLICK_HANDLERS.md` is created.
- [ ] Documentation clearly explains the new capabilities using examples.
