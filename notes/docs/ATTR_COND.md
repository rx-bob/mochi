# Mochi Attribute Conditionals

In Mochi, adding conditional or dynamic logic to HTML attributes requires specific compiler treatment because standard structural conditionals (like `{if @active} <div> </div> {end}`) rely on HTML comment anchors (e.g. `<!--if-anchor-->`) inserted into the DOM. Inserting these comment anchors inside an HTML attribute string (e.g., `class="<!--if-anchor-->"`) breaks HTML parsing and prevents the reactive engine from correctly updating the attribute.

Mochi solves this through two approaches that extract the logic out of the attribute and into computed Ruby methods: **Attribute Conditionals** and **Hash-Based Attribute Binding**.

---

## 1. Attribute Conditionals (Inline `{if}` and `{unless}`)

You can use standard Mochi conditionals directly inside an attribute string.

```html
<a class="nav-item {if @is_active}active{end} {unless @enabled}disabled{end}">
  Link
</a>
```

### How it Works Under the Hood

1. **Extraction (`AttributeConditionalExtractor`)**: Before the HTML is parsed by `Lexbor`, this preprocessor phase finds any attribute containing `{if` or `{unless`. It replaces the entire attribute string with a unique token, like: `class="{__mochi_attr_cond_0}"`.
2. **Method Generation (`AttributeMethodGenerator`)**: The compiler parses the original conditionals and generates a computed Ruby method in the component's class:
   ```ruby
   def __mochi_attr_cond_0
     _res = "nav-item "
     if @is_active
       _res += "active"
     end
     _res += " "
     unless @enabled
       _res += "disabled"
     end
     _res
   end
   ```
3. **Reactivity (`InstanceVarAnalyzer`)**: Mochi analyzes the generated method or the original HTML interpolation to identify reactive signals (like `@is_active`). The runtime treats `__mochi_attr_cond_0` like an internal reactive property, preventing it from leaking to the DOM as an observable attribute while still calling `setAttribute` whenever `@is_active` changes.

---

## 2. Hash-Based Attribute Binding (`class={{...}}`)

For dynamic attributes with many toggles (such as CSS classes), Mochi provides a Ruby-native Hash syntax inspired by Rails and ViewComponent.

```html
<!-- You can use string keys and hash rockets -->
<a class={{ "nav-item" => true, "active" => @is_active }}>Link</a>

<!-- Or newer symbol syntax -->
<a class={{ "nav-item": true, "active": @is_active }}>Link</a>
```

If the value evaluates to a truthy object, the key is included in the final attribute string.

### How it Works Under the Hood

Hash Attributes follow a very similar pipeline to Attribute Conditionals:

1. **Extraction (`AttributeHashExtractor`)**: Before `Lexbor` parses the HTML, it finds any attribute set to `{{...}}` (with or without surrounding quotes). Since `{{...}}` isn't strictly valid HTML if it contains quotes, we must extract it early. It replaces the attribute with a token: `class="{__mochi_attr_hash_0}"`.
2. **Method Generation (`AttributeHashGenerator`)**: The compiler generates a Ruby method that evaluates the Hash, selects the truthy values, and joins the keys with a space:
   ```ruby
   def __mochi_attr_hash_0
     _hash = { "nav-item" => true, "active" => @is_active }
     _hash.select { |k, v| v }.keys.join(" ")
   end
   ```
3. **Reactivity**: Just like attribute conditionals, the generated `__mochi_attr_hash_0` variable is tracked by the JS generation engine. When `@is_active` updates, the runtime recalculates the hash and updates the DOM using `setAttribute`. The JS components (`LegacyComponentGenerator` & `NewComponentGenerator`) explicitly keep these internal bindings hidden from standard `observedAttributes`.

---

## Conclusion

Attribute conditionals (`{if}`) allow fine-grained string interpolation, while Hash-Based Binding (`{{...}}`) offers clean, declarative toggling of attributes based on boolean logic. Both features keep your components clean by offloading the string concatenation to Mochi's compiler behind the scenes.
