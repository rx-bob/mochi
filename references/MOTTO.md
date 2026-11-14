# Mochi's North Star

**Everything a Ruby developer needs to build a browser application. Only the bytes that application needs to run.**

## Ruby is the complete developer experience

A Ruby developer must be able to build, test, debug, and ship a browser application without writing or understanding JavaScript.

Mochi owns the application model, browser APIs, and tooling needed to make that possible. Ruby semantics should be consistent across application methods, components, templates, and event handlers. Errors should point to the developer's Ruby source.

JavaScript may be an internal implementation detail. Reusing a JavaScript library is acceptable when Mochi exposes a complete Ruby interface and handles conversion, asynchronous execution, errors, lifecycle, and cleanup underneath. Developers must not need JavaScript knowledge, manual script tags, or direct JavaScript interop to complete their application.

“Use JavaScript” is not a resolution to a missing Mochi capability. Unsupported features may be explicit limitations while the platform grows, but they remain Mochi's responsibility.

## A complete platform with a small core

Mochi prioritizes very small shipped payloads. Platform completeness does not mean bundling every capability into every application.

Keep the core focused on the VM, essential Ruby semantics, component lifecycle, reactivity, and DOM updates. Ship additional capabilities as optional modules, and load application components and their dependencies as needed through `.chi` files and the loader.

The compiler and loader should handle dependency resolution and loading through the Ruby development experience. Features an application does not use should add no payload wherever practical; any unavoidable core cost must be explicit and justified.

Small `.chi` files alone are not enough. Optional functionality bundled into the initial WASM runtime still costs every application bytes. Distinguish capabilities that can load as Ruby bytecode from those requiring additional host or VM support, and design their loading boundaries accordingly.

## How we make decisions

Evaluate changes against these questions:

- Can a Ruby developer use and debug this without learning JavaScript?
- Does it preserve consistent Ruby and component behavior?
- What does it add to an application that does not use it?
- Can it load only when needed, with dependencies and cleanup handled by Mochi?
- What are the measured costs in compressed initial payload, subsequent feature downloads, startup time, and runtime resources?

Establish and maintain payload budgets for a minimal application and representative real screens. Treat core growth as an explicit engineering decision.

Correctness and resource lifetimes are part of this promise. Small downloads must not come at the expense of broken composition, lost application state, or resource accumulation in long-running applications.
