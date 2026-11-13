# API migrations

This page covers user-visible contract changes. New browser APIs remain Ruby
interfaces and are loaded only when an application uses their package.

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

See [money contracts](MONEY_CONTRACT.md) for exact accumulation and display
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
