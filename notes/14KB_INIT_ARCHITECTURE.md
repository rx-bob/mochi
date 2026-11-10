# Mochi Architecture: The 14kB First-Paint & Lazy Hydration Strategy

To achieve truly "instant" perceived load times, Mochi is pivoting its architecture to respect the **TCP Slow Start 14kB limit**. This ensures the initial visual state of a website is delivered in a single network round-trip.

This architecture shifts Mochi from a traditional Single Page Application (SPA) model—where a heavy JS/Ruby runtime must load before anything renders—to a **Static-First, Resumable/Hydrated** model.

---

## 1. The Core Philosophy: "Hollow Shells"

The browser should never wait for Ruby (via Opal or WASM) to download, parse, and execute just to see the UI. 

Instead, the Mochi compiler acts as a Static Site Generator (SSG) for the initial render.

1. **Build Time:** The Mochi compiler executes the `#html` and `#css` methods of your Ruby components during the build step.
2. **Output:** It generates a raw `index.html` file where the Web Components (e.g., `<my-counter>`) already contain their inner HTML and scoped CSS injected into the Light DOM or Declarative Shadow DOM.
3. **The Payload:** The server sends standard HTML, inline critical CSS, and a tiny (~1kB) JavaScript Bootstrapper. 
4. **Result:** The user sees a fully styled, complete page instantly. It fits well within the 14kB compressed limit.

---

## 2. The 1kB JS Bootstrapper (The Orchestrator)

The initial payload contains no Ruby logic and no heavy runtimes. Instead, it includes a microscopic JavaScript file called the "Mochi Bootstrapper".

**Its responsibilities:**
1. Setup an `IntersectionObserver`.
2. Scan the DOM for Mochi Web Components (e.g., elements with a `data-mochi-hydrate` attribute).
3. If a component comes into the viewport (or is hovered/tapped), the Bootstrapper initiates the download of the Mochi Runtime and the specific logic for that component.

```javascript
// Conceptual Bootstrapper
const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      const cmp = entry.target;
      const componentName = cmp.tagName.toLowerCase();
      
      // Lazy load the runtime and the component's logic
      import('./mochi-runtime.js').then(runtime => {
        import(`./components/${componentName}.js`).then(module => {
          // "Wake up" the component
          runtime.hydrate(cmp, module.default);
        });
      });
      
      observer.unobserve(cmp);
    }
  });
});

document.querySelectorAll('[data-mochi-hydrate]').forEach(el => observer.observe(el));
```

---

## 3. Hydration: Waking up the Components

Once the Bootstrapper downloads the logic for a visible component, it "hydrates" it.

Because the HTML is already in the DOM (thanks to the initial server render), Mochi does not need to re-render the template. 
1. The JS/WASM module is loaded.
2. The internal Ruby class state (e.g., `@count = 0`) is initialized.
3. Mochi attaches event listeners (e.g., `onclick`) to the existing DOM nodes.
4. The component is now fully interactive.

*(If a user clicks a button before the runtime is loaded, the Bootstrapper can catch the event, hold it, force the download, and then replay the event once the component is awake).*

---

## 4. The Runtime: Opal vs. WebAssembly (ruby.wasm)

By lazy-loading the runtime, we buy ourselves flexibility in what that runtime is. We no longer fail the 14kB test, giving us two distinct paths for the interactive layer:

### Option A: The Opal Route (Current, but Lazy)
* **How:** We compile Ruby to JS using Opal, but split the code heavily.
* **Pros:** JS is relatively small, integrates perfectly with Vite, and DOM manipulation is native and fast.
* **Cons:** Opal has Ruby compatibility quirks.

### Option B: The WebAssembly Route (ruby.wasm)
* **How:** The Bootstrapper downloads a stripped-down `mochi-ruby.wasm` runtime. Individual components are compiled into a binary format or just served as raw `.rb` text that the WASM engine evaluates.
* **Pros:** True, standard MRI Ruby semantics. Massive hype factor ("Ruby in the browser via WASM").
* **Cons:** WASM binaries are large (500kB - 2MB). Even if lazy-loaded, the "Time to Interactive" (when a user clicks a button and waits for WASM to boot) might be noticeable on slow connections. The JS<->WASM DOM bridge adds overhead.

### Recommendation
**Start with Opal but design the Bootstrapper to be runtime-agnostic.** 
Because the Bootstrapper just says "fetch logic for this tag and attach it," it doesn't matter if the logic is backed by `Opal.Counter.$new()` or a `WASM.call('Counter.new')`.

---

## 5. Synergy with the Vite Architecture

This 14kB Resumable Architecture pairs perfectly with the previously discussed "Single File Loader" (Vite) approach.

* Mochi acts as a Vite Plugin.
* It outputs an HTML file with the static representation of the components.
* It outputs standard ES Modules for the Ruby logic (`import "./counter.rb"`).
* **Vite handles the rest:** Vite sees the dynamic `import()` statements in the Bootstrapper and automatically code-splits the Opal runtime and the individual components into separate, lazy-loaded network chunks. 

Mochi writes the Ruby-to-JS bridge; Vite optimizes the delivery network.