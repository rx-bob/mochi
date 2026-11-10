# Cross-Component Communication (Event Bus)

In Mochi, components are typically encapsulated within their own Shadow DOM. Historically, communicating between two separate components (like a Sidebar and a Top Navigation bar) required piercing the DOM via raw JavaScript `document.querySelector('...').shadowRoot`.

Mochi now includes a robust native **Inter-Component Event Bus** accessible directly from Ruby.

## API Basics
Mochi components automatically include two helper methods to interface with the global event registry: `emit` and `on`.

### emit(event_name, payload = nil)
Publishes an event to the global Mochi Event Bus. Any component listening to `event_name` will instantly execute its callback.

### on(event_name, &block)
Subscribes to an event on the global Event Bus. The provided block will trigger whenever `emit` is called for that event anywhere in the app.

---

## Real World Example: Sidebar Toggle
Imagine a `TopNav` component with a hamburger icon, and a `Sidebar` component that slides in and out when toggled.

### 1. Publishing the Event (`TopNav.rb`)
```html
<nav>
  <button onclick="{toggle_menu}">Menu</button>
</nav>
```

```ruby
class TopNav
  def init
    @menu_open = false
  end

  def toggle_menu
    @menu_open = !@menu_open
    
    # Broadcast to the rest of the application
    emit(:sidebar_toggled, { is_open: @menu_open })
  end
end
```

### 2. Subscribing to the Event (`Sidebar.rb`)
```html
<aside class={{"sidebar": true, "slide-in": @expanded}}>
  <ul>
    <li>Home</li>
    <li>Settings</li>
  </ul>
</aside>
```

```ruby
class Sidebar
  def init
    @expanded = false
  end

  # The idiomatic place to register listeners is `mounted`
  def mounted
    on(:sidebar_toggled) do |payload|
      # `payload` is converted from JS into an Opal object natively!
      @expanded = payload[:is_open]
    end
  end
end
```

## Automated Memory Management
In traditional Single Page Applications (SPAs), failing to manually unregister global event listeners when a component unmounts leads to Memory Leaks and phantom executions.

**Mochi handles cleanup automatically.**

When you call `on(:event)`, Mochi internally tracks your subscription. If the `Sidebar` element is removed from the DOM (e.g., destroyed by an `{if}` block), the Mochi JavaScript engine detects the Web Component's `disconnectedCallback` hook and immediately calls `Mochi.off` to deregister your block.

You do not need to write `off(:event)` inside a cleanup method. Memory leaks are structurally prevented!
