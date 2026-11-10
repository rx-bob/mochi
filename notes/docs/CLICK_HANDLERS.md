# Context-Aware Event Handlers in Mochi

Mochi event handlers seamlessly connect DOM events to your Ruby component methods. Mochi recently upgraded its event system to move away from the Svelte-like `on:click` syntax in favor of standard HTML-native attributes (`onclick`, `onchange`, etc.).

Beyond syntax, Mochi now brings powerful "context-aware" capabilities, allowing you to pass arguments directly to your Ruby functions right from the HTML attribute.

## 1. Syntax Update: `on:click` -> `onclick`
Mochi seamlessly intercepts standard HTML event attributes (`onclick`, `onchange`, `onsubmit`, etc.) when evaluating your components. Do **not** use `on:click` anymore.

**Old Syntax:**
```html
<button on:click="{save}">Save</button>
<input on:change="{update}" />
```

**New Syntax:**
```html
<button onclick="{save}">Save</button>
<input onchange="{update}" />
```

## 2. Passing Arguments Explicitly
You can now pass arguments explicitly inside the curly braces of the event handler. These arguments are evaluated in the **JavaScript Context** when the click happens natively in the browser.

This is especially powerful when iterating over `{each}` loops, as Mochi captures the local iteration variable and safely plumbs it all the way to your Ruby backend.

**HTML Template:**
```html
<div class="user-list">
  {each @users as user}
    <!-- `user.id` is evaluated natively when the button is clicked! -->
    <button onclick="{delete_user(user.id)}">Delete User</button>
  {end}
</div>
```

**Ruby Component:**
```ruby
def delete_user(id)
  puts "Deleting user #{id}"
end
```

### The `$event` and `$element` Magical Variables
Sometimes, you need access to the browser's raw underlying `Event` object or the `HTMLElement` that triggered the interaction. You can explicitly request these by passing `$event` or `$element` into your arguments list.

```html
<button onclick="{log_click($event, $element, 123)}">Click Me</button>
```

```ruby
# Both native objects are bridged into Opal
def log_click(event, target, user_id)
  puts "Event coordinates: #{event.clientX}, #{event.clientY}"
  puts "Button Class: #{target.className}"
end
```

## 3. Implicit Argument Passing: `dataset`
If you do not pass explicit arguments, Mochi automatically appends the element's `dataset` attribute (all of its `data-*` properties) to your Ruby method as a Hash fallback. This mimics classical HTML/Ruby server-side approaches.

The `dataset` hash will be passed as the **final parameter** to the Ruby method. For `onclick` this is the only parameter if no `(...)` was utilized. For `onchange`, Mochi traditionally passes `(event, value)`. In that case, the dataset is the third parameter: `(event, value, dataset)`. 

**HTML Template:**
```html
<button data-id="{user.id}" data-role="admin" onclick="{delete_user}">Delete User</button>
```

**Ruby Component:**
```ruby
def delete_user(dataset)
  puts "Deleting user #{dataset["id"]} with role #{dataset["role"]}"
end
```

---

*Note: Behind the scenes, the Mochi compiler uses an `EventArgumentExtractor` that translates inline parenthesis arguments like `onclick="{method(arg1)}"` into native `data-mochi-arg-0="{arg1}"` DOM attributes to guarantee variables are scoped and tracked interactively by the javascript engine before sending them to Opal.*
