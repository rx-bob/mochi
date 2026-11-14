# API migrations

This page covers user-visible contract changes. New browser APIs remain Ruby
interfaces and are loaded only when an application uses their package.
For checked task examples, see the [Ruby task guide](RUBY_TASK_GUIDE.md).

## Global events

`Mochi.emit` used to broadcast an action name to every mounted component with a
matching method. It now publishes a named event only to components that call
`Mochi.subscribe`. `target:` is no longer a component filter; remove it and
register each intended receiver explicitly.

Before:

```ruby
def publish
  Mochi.emit("profile_opened", id: "tr_1")
end

def profile_opened(payload)
  @profile_id = payload[:id]
end
```

After:

```ruby
def mounted
  Mochi.subscribe("profile_opened", :profile_opened)
end

def stop_listening
  Mochi.unsubscribe("profile_opened", :profile_opened)
end

def publish
  Mochi.emit("profile_opened", id: "tr_1")
end

def profile_opened(payload)
  @profile_id = payload[:id]
end
```

Subscriptions belong to one mounted component instance. The loader removes
them at disposal, including when a mount fails. Explicit `unsubscribe` is
useful when a live component no longer wants future events. An emitter does not
receive its own event unless it subscribes, and a method name alone never
registers a receiver. Typed parent/child events declared with `event` and
`on:<event>` keep their existing scoped behavior.

Registration in `initialize` or `mounted` is supported, but delivery begins
only after that component is ready. Publications before readiness are skipped,
not replayed; they do not unregister the pending receiver. Duplicate
event/handler/instance registrations are idempotent. Subscribe/unsubscribe and
emit in a single handler follow Ruby statement order, including self-subscription.

Child event attributes must contain exactly one braced Ruby handler, for
example `on:action="{handle($event)}"`. Unbraced values such as
`on:action="handle"`, empty values, and values mixed with literal text now fail
compilation at the authored attribute. Multiple child events on one element
remain supported.

Payloads must be Hashes containing transportable values (nested Hash/Array,
String/Symbol, finite number, boolean, or nil), with String/Symbol keys.
Objects, cycles, non-finite numbers and nesting deeper than 16 levels raise a
source-located error instead of silently converting to strings or null. Symbol
values use their string names on the wire. The compiled event capacity bounds
traversal and serialized output. A rejected publication is not delivered.

This change affects global publications only. Routes and storage retain their
explicit subscriber maps; timers and fetch completions target their owning
instance directly. Focus commands and keyboard/local action handlers retain
their existing direct dispatch paths. Declared child events still validate
their contracts and target the exact parent instance.

Global publications use a FIFO snapshot of the subscriptions that exist when
each event is published. A receiver removed before its queued turn is skipped;
a receiver added during delivery starts with the next publication. Reentrant
chains stop at the active VM profile's `host_event_queue_entries` or
`host_event_queue_bytes` bound and report one source-located `mochi:error` with
the event and subscription context. Mochi clears the offending queued work;
other queued publications and later independent events can still run.

## Numeric and currency contracts

Ruby `Integer` uses checked signed 64-bit arithmetic; overflow raises a
source-located error instead of wrapping. `Float` uses binary64, so it is not
an exact decimal representation. Use `round`, `floor`, or `ceil` when choosing
a numeric rounding operation, and use `MochiMoney` for exact fractional minor
units.

`MochiFormat.currency` takes an integer count of minor units. Code that passed
a fractional major-unit amount must convert explicitly and choose a rounding
rule:

```ruby
# Before: fractional major units passed directly to currency formatting
MochiFormat.currency(12.345, "USD", "en-US", 2)

# After: exact accumulation, then explicit rounding to integer cents
ledger = MochiMoney.amount(12_345, 10) # 1,234.5 minor units
cents = MochiMoney.round_half_up(ledger)
MochiFormat.currency(cents, "USD", "en-US", 2)
```

See [money contracts](../AGENTS.md#money-helpers) for exact accumulation and display
rounding, and [Ruby surface](RUBY_SURFACE.md) for supported numeric and
collection methods.

## Fixed capacities and optional browser APIs

VM scratch space, host event delivery, file reads, and other configured
resources have build-time limits. Capacity exhaustion reports a Ruby source
location and stops the current operation; limits do not grow at runtime. Keep
the default profile unless a measured application need requires a custom
profile. See [capacity contract](CAPACITY_CONTRACT.md) and
[fixed-capacity configuration](../docs/fixed-capacities.md).

Pointer capture, drag transfer, and file access are opt-in Ruby APIs. Do not add
JavaScript script tags to use them; require or call the Ruby surface documented
in [pointer contracts](POINTER_CONTRACT.md) and
[drag and file contracts](DRAG_FILE_CONTRACT.md). File APIs retain opaque
mount-owned handles, stream in bounded chunks, and cap whole-file reads.

## Three UI fixtures: current contracts

These contracts replace application workarounds; they do not require JavaScript.
The [fixture guide](../e2e/fixtures/ui_contracts/README.md) contains complete
buildable Ruby sources and authored browser scenarios. The
[new feedback inventory](UI_FIXTURE_CONTRACTS.md) is separately numbered from
the older [feedback inventory](FEEDBACK_CONTRACTS.md).

| Previous assumption/workaround | Current supported form |
| --- | --- |
| Manual scalar loops for pagination | `rows.slice(start, length)` and `rows[start, length]` return fresh shallow arrays with Ruby boundary behavior; [slice contract](RUBY_SURFACE.md#array-indexing-and-slicing). |
| Inline helper data to avoid qualified lookup | Top-level helper constants/singleton calls and local block `next` work across initializer, method, event and template contexts; [helper contract](RUBY_SURFACE.md#helper-constants-receivers-and-block-control-flow). |
| Manual cache/epoch to share a derived projection | Declare pure zero-argument `computed` methods with explicit root/computed dependencies; replace owning collection roots to publish edits. Same-handle assignment and hidden deep mutations do not invalidate; [computed contract](RUBY_SURFACE.md#explicit-computed-values). |
| Duplicate setter calls inside an input handler | Binding synchronizes first for the same native event, then evaluates arguments and invokes the explicit handler once, regardless of attribute order; [binding contract](RUBY_SURFACE.md#bound-controls-and-explicit-handlers). |
| Assume `dataset` identifies a clicked row's handler | `dataset` and `target_dataset` retain target semantics. Use `event["current_target_dataset"]["id"]` for bound-row identity, including descendant clicks; [event contract](RUBY_SURFACE.md#native-event-identity). |
| Treat required/defaulted Boolean props as Strings | Use `prop :required, Boolean, required: true` and `prop :disabled, Boolean, default: false`; build/typecheck and typed child-event validation agree; [Boolean contract](RUBY_SURFACE.md#boolean-props-child-events-and-form-controls). |
| Import a project-root CSS directory | Keep shared fragments under `lib/styles/`; a `lib/MyCounter.rb` imports `./styles/controls.css`. Root `styles/` is not staged. Public assets retain `public/`; icons are project assets, not a built-in catalog. |

Optional [layout](LAYOUT_CONTRACT.md), [wheel](WHEEL_CONTRACT.md), and
[shortcut](SHORTCUT_CONTRACT.md) APIs own registrations, batching and cleanup.
[JSON](RUBY_SURFACE.md#optional-json) preserves signed64 integers within document
bounds. [Time](RUBY_SURFACE.md#optional-wall-clock-and-unix-timestamps) uses Unix
seconds; inspector source timestamps remain milliseconds and convert explicitly.
[Downloads](DOWNLOAD_CONTRACT.md) start synchronously during user activation;
capabilities are ready before controls render. Accepted URL leases survive
unmount until bounded expiry, unlike canceled mount-owned callbacks/readers.

Do not infer full MRI/Regexp/Date/Math, slots, SVG custom-element composition,
automatic deep observation, arbitrary DOM access, save pickers/streaming output,
or a graph/form library from these fixtures. Bounded file streaming already
exists; general import/export products remain deferred. Failures discard pending
DOM/host work, not prior Ruby state mutations. Recovery and each retained
limitation have explicit evidence in the inventory.
