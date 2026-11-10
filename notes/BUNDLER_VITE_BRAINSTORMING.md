# Mochi: Bundler vs Vite 8 Integration Brainstorming

Mochi sits in a fascinating middle ground: it’s targeting the modern web (Web Components) but writing in a language with its own deep, established ecosystem (Ruby/Sorbet). 

Since Mochi is compiled via Crystal, relies on Opal/Ruby gems for dependencies, and ultimately outputs JavaScript for the browser, we are dealing with two distinct developer personas:

1. **The "Ruby Purist"**: Wants to avoid Node.js, `package.json`, and JS tooling entirely. They want to use `Bundler`, `Gemfile`, and feel like they are writing native Ruby.
2. **The "Modern Frontend Dev"**: Loves Ruby's syntax but wants the blistering speed, Hot Module Replacement (HMR), and massive asset ecosystem (Tailwind, PostCSS, etc.) of Vite 8.

Here is a brainstorming guide on how to architect Mochi to gracefully support **both** paradigms without fragmenting the core compiler logic.

---

## 1. The Core Architecture: "Compiler as a Service"
To support multiple ecosystems, the Mochi compiler (written in Crystal) should remain completely agnostic to the build tool. 

Instead of Mochi *being* the bundler, Mochi should act as a **transformation engine**.
* **Input:** A `.rb` file (or a directory of them), plus a list of Ruby load paths (from Bundler).
* **Output:** Standard JavaScript (ES Modules) containing the Web Components.

By keeping the CLI fast and focused (`mochi build -i src -o dist`), we make it trivial to wrap Mochi in whatever tooling the user prefers.

---

## 2. The Bundler/Ruby-First Approach (Natural Feel)
For developers who want a pure Ruby experience, Bundler is essential anyway because they will likely want to import Ruby gems (via Opal) into their frontend code.

**How to implement:**
* **`mochi` Gem:** Create a Ruby gem that acts as a wrapper around the Crystal binary. When they run `bundle exec mochi dev`, it boots.
* **Dependency Resolution:** The gem can use `Bundler.setup` to automatically extract the load paths of all installed gems and pass them to the Crystal compiler via CLI flags (e.g., `mochi -i src --load-path /vendor/bundle/...`).
* **The Dev Server:** Instead of relying on a JS tool, Mochi (via Crystal) can run its own blazing-fast, built-in HTTP server and file watcher. When a `.rb` file changes, Crystal incrementally compiles it and triggers a simple Live Reload (via Server-Sent Events or WebSockets) to refresh the browser.
* **Rails Integration (Optional but huge):** Eventually, we could create a `mochi-rails` gem that hooks into Propshaft or Sprockets, allowing people to drop Mochi web components directly into standard Rails views.

**Pros:** Zero Node.js dependencies. Feels like "Frontend Ruby."
**Cons:** Lacks advanced HMR (Hot Module Replacement) and modern CSS processing out of the box.

---

## 3. The Vite 8 Approach (The Web Ecosystem)
Vite 8 is undeniably the king of the modern frontend. If someone wants to use TailwindCSS, import SVGs, or mix Mochi components with a React app, Vite is the way to go.

**How to implement:**
* **`vite-plugin-mochi`:** Create an npm package. 
* **The Plugin Workflow:**
  1. A user writes `import './components/counter.rb'` in their `main.js`.
  2. Vite intercepts the `.rb` import.
  3. The Vite plugin shells out to the Mochi compiler (or communicates via a fast local socket/daemon) asking it to compile `counter.rb`.
  4. Mochi returns the JavaScript string representing the Web Component.
  5. Vite caches it, serves it, and bundles it for production.
* **HMR for Ruby:** Web Components can be notoriously tricky to hot-reload, but because we control the compiler, we could have Mochi emit Vite-specific `import.meta.hot` snippets in dev mode. When `counter.rb` changes, Vite replaces the class definition and re-renders the component without reloading the page.

**Pros:** Access to the entire NPM ecosystem, blazing fast dev server, amazing asset pipeline.
**Cons:** Requires `package.json` and Node.js.

---

## 4. The Hybrid Strategy: How to support both seamlessly

We don't have to build both at the same time, but we can structure Mochi to allow both to exist peacefully:

**Phase 1: The "Mochi Config" File**
Create a `.mochirc.json` (or `mochi.yml`) at the root of a project. 
This configuration file tells the Mochi Crystal compiler how to behave, regardless of who is calling it (Vite or Bundler).
```json
{
  "entrypoints": ["src/main.rb"],
  "outDir": "dist",
  "gemfile": "Gemfile" // Tells Mochi to ask Bundler for load paths
}
```

**Phase 2: The Two Starter Templates**
When a user runs `mochi --initialize="my_project"`, give them an interactive prompt:

```text
How would you like to build your Mochi app?
❯ Pure Ruby (Bundler + Built-in Dev Server) - Best for Rubyists
❯ Modern Web (Vite 8 + NPM) - Best for Tailwind, HMR, and JS ecosystems
```

* **If they choose Pure Ruby:** Generate a `Gemfile`, `src/`, and configure the Mochi CLI to use its internal file-watcher and simple HTTP server.
* **If they choose Modern Web:** Generate a `package.json` with `vite` and `vite-plugin-mochi`, a `vite.config.js`, and a `Gemfile` (strictly for Sorbet/Ruby dependency resolution).

## Summary of the "Best of Both Worlds" Architecture

1. **Compiler (Crystal):** Does one thing perfectly—takes Ruby/Sorbet AST, uses Opal/Custom generators, and outputs JS Web Components.
2. **Dependency Manager (Bundler):** Solves *where* the Ruby files are (even in Vite projects, Bundler is used under the hood to resolve Ruby library paths before passing them to the compiler).
3. **Asset Pipeline / Server (Vite OR Built-in):** Handles the CSS, HTML serving, and watching. The user chooses which one they want via templates.

This approach respects the Ruby community's desire for simplicity while leaving the door wide open for the broader JavaScript community to adopt Mochi as "just another Vite framework." 
