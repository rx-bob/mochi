# Inter-Component Event Bus (Cross-Shadow-DOM Communication)

## Problem Context
Currently, if two separate Mochi components need to communicate (e.g., a Top Navigation Bar changing the active state of a Sidebar, or TOC scroll tracking updating a header), developers are forced to write raw JavaScript that reaches through the DOM:
`document.querySelector('other-component').shadowRoot.querySelector('.thing')`

This breaks encapsulation, is brittle to DOM changes, and doesn't feel like a modern Component framework. We need a lightweight, Ruby-esque inter-component Event Bus (`Mochi.emit` / `Mochi.on`) to handle decoupled pub/sub communication safely.

---

## Execution Plan: Epics & Stories

### Epic 1: Core Mochi Event Bus (JavaScript Base)
*Implement a lightweight global pub/sub system on the `window.Mochi` object.*

#### Story 1.1: Implement `Mochi.emit`, `Mochi.on`, and `Mochi.off`
**Goal:** Add a global event registry to the Mochi runtime kernel that allows components to publish and subscribe to named events.
**Details:**
- In `runtime_kernel.cr` (or the equivalent file where `window.Mochi` is initialized), add an `_events` object to store arrays of callback functions keyed by event names.
- Implement `Mochi.on(eventName, callback)` to append callbacks.
- Implement `Mochi.off(eventName, callback)` to remove specific callbacks.
- Implement `Mochi.emit(eventName, payload)` to sequentially execute all registered callbacks for that event, passing the `payload`.
**Acceptance Criteria:**
- [ ] `window.Mochi.on`, `off`, and `emit` are globally available in the browser.
- [ ] Calling `emit` correctly triggers all callbacks registered via `on` with the provided payload.

### Epic 2: Ruby Runtime Bridging & Lifecycle Management
*Expose the event bus to the Ruby components and automate memory management to prevent leaks.*

#### Story 2.1: Implement Ruby `emit` and `on` API
**Goal:** Give Ruby components idiomatic methods to interact with the event bus.
**Details:**
- In the base Ruby component class/module (or via Opal JS interop inside the transpiler), add a `def emit(event_name, payload = nil)` method that bridges to `` `window.Mochi.emit(#{event_name}, #{payload.to_n})` ``.
- Add a `def on(event_name, &block)` method that bridges to `` `window.Mochi.on(...)` ``.
**Acceptance Criteria:**
- [ ] Developers can call `emit(:sidebar_toggled, { expanded: true })` from any Ruby method.
- [ ] Developers can call `on(:sidebar_toggled) { |data| ... }` (e.g. inside their `mounted` or `init` lifecycle methods).

#### Story 2.2: Automated Event Listener Cleanup (Memory Leak Prevention)
**Goal:** Ensure that when a component unmounts (e.g., is removed from the DOM by an `if` block), any global event listeners it registered are automatically cleaned up.
**Details:**
- When a component calls `on(:event)`, the framework should track that subscription internally within the component instance.
- In both `LegacyComponentGenerator.cr` and `NewComponentGenerator.cr`, update the `disconnectedCallback` (unmount hook) to iterate through the component's tracked subscriptions and automatically call `Mochi.off()` for each one.
**Acceptance Criteria:**
- [ ] If a component is destroyed, its event listeners are successfully deregistered from `window.Mochi._events`.
- [ ] No manual `.off` calls are required from the developer when a component is destroyed.

### Epic 3: Cleanup Legacy Cross-Component Logic
*Remove existing workarounds from the framework and examples.*

#### Story 3.1: Refactor Raw DOM Queries
**Goal:** Identify any places in the Mochi compiler, examples, or testing specs where raw `shadowRoot` piercing was used for cross-component communication, and replace them with the new Event Bus.
**Details:**
- Search the codebase (specifically spec data like `a_layout.rb` or sample apps) for `.shadowRoot` or `.querySelector('other-component')`.
- Refactor these instances to utilize the idiomatic `emit` and `on` Ruby API.
**Acceptance Criteria:**
- [ ] Legacy `.shadowRoot` piercing is removed from inter-component communication examples.
- [ ] The test suite still passes successfully with the new architecture.

### Epic 4: Documentation
*Provide clear documentation on how developers can use the Event Bus.*

#### Story 4.1: Write `notes/docs/CROSS_COMP_COMMS.md`
**Goal:** Create a comprehensive guide explaining how to publish and subscribe to events across the application.
**Details:**
- Write documentation detailing the `emit(:event, payload)` and `on(:event) { |payload| ... }` API.
- Explicitly mention that cleanup is handled automatically during component unmounting, so developers don't have to worry about memory leaks.
- Provide a clear, real-world code example (e.g., a Sidebar and a Top Nav communicating).
**Acceptance Criteria:**
- [ ] A new file `notes/docs/CROSS_COMP_COMMS.md` is created.
- [ ] Documentation clearly explains the capabilities using Ruby-native examples.
