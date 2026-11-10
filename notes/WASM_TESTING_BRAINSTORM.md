# Testing Strategy for the "Extreme MRI" Architecture

This document outlines the testing strategy for Mochi components within the parser-less WebAssembly (WASM) architecture. Because Mochi components are written in standard Ruby but execute inside a specialized WASM environment with a custom Virtual DOM, we need a multi-layered approach to testing.

We **do not** need to build a massive testing framework from scratch. Instead, we leverage the existing Ruby ecosystem (Minitest/RSpec) with clever Mochi-specific mocking, followed by true WASM execution for parity.

---

## Phase 1: Pure MRI Testing (The "Headless Ruby" Approach)

The core advantage of the Extreme MRI architecture is that a Mochi component is just a plain Ruby class that updates internal instance variables and mutates a Virtual DOM. It doesn't rely on the heavy JS interop that Opal requires.

This means developers can use standard **Minitest** or **RSpec** running on their local machine (without WASM or browsers) to test the pure logic of their components.

### How it works:
1.  Publish a tiny `mochi-test` Ruby gem.
2.  When a developer runs `rspec` or `minitest`, this gem requires their components but injects a **Mock Virtual DOM**.
3.  When the component calls `render` or mutates state, the mock intercepts the opcodes (instead of writing them to the WASM Shared Memory) and allows the developer to assert against them.

### Example User Experience (RSpec):
```ruby
# spec/counter_component_spec.rb
require 'mochi/test_helper'
require_relative '../src/counter_component'

RSpec.describe CounterComponent do
  it 'increments the count' do
    component = Mochi::Test.mount(CounterComponent)
    
    # Assert initial state
    expect(component.state(:@count)).to eq(0)
    
    # Trigger the action
    component.call(:increment)
    
    # Assert new state
    expect(component.state(:@count)).to eq(1)
  end

  it 'renders the correct HTML' do
    component = Mochi::Test.mount(CounterComponent)
    component.call(:increment)
    
    # Assert against the Mock Virtual DOM output
    expect(component.render_output).to include("Count is: 1")
  end
end
```

**Why this is great:** It is blazing fast. Developers get the sub-millisecond feedback loop of standard Ruby testing for 95% of their logic without the overhead of spinning up WASM or browser engines like Playwright.

---

## Phase 2: WASM-Native Unit Testing (The "True Parity" Approach)

While Phase 1 is fast, it doesn't run the code in the actual environment it will execute in (32-bit WASM with stripped C-extensions). To guarantee absolute parity without the overhead of Playwright, Mochi will provide a headless WASM test runner.

### How it works:
1.  Mochi ships with a CLI command: `mochi test`.
2.  Behind the scenes, this command:
    *   Compiles the user's `_spec.rb` files into `.yiseq` binaries.
    *   Spins up a headless WASM engine (like Wasmtime or a Node.js WASM host).
    *   Loads the custom `mochi-ruby-micro.wasm` runtime and the `.yiseq` files.
    *   Executes the tests inside the WASM memory space and streams the `stdout` (test results) back to the developer's terminal.

### The Architecture of `mochi test`:
Instead of building an entirely new test syntax, Mochi can include a minimalist clone of Minitest (or support a subset of it) directly compiled into the `mochi-ruby-micro.wasm` core. 

When the user types `mochi test`, they are actually running a highly optimized WASM binary that evaluates their bytecode and asserts the memory state exactly as the browser would.

---

## Summary Recommendation

1.  **Do not reinvent the syntax.** Rubyists love RSpec and Minitest. Support the testing idioms they already know.
2.  **Start with the Mocked MRI approach.** Build a `mochi-mock` library that stubs out the WASM Shared Memory bridge. This allows users to test their component logic using their existing local Ruby tools immediately.
3.  **Later, build `mochi test`.** Once the WASM pipeline is stable, introduce the headless WASM runner to guarantee 100% environment parity for CI pipelines. 
4.  **Keep Playwright for E2E.** The actual "Did the JS Painter correctly update the browser DOM?" question should remain strictly in the realm of End-to-End testing (Playwright/Cypress). This cleanly separates logical testing from render-layer testing.