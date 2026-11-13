# API migrations

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
Objects, cycles, non-finite numbers and nesting deeper than 16 levels now raise
a source-located error instead of silently converting to strings or null.
Symbol values use their string names on the wire.
The compiled emit capacity also bounds traversal and serialized output. No
publication from a rejected handler is delivered.

This change affects global publications only. Routes and storage retain their
explicit subscriber maps; timers and fetch completions target their owning
instance directly. Focus commands and keyboard/local action handlers retain
their existing direct dispatch paths. Declared child events still validate
their contracts and target the exact parent instance.

E4.S1 validation: 149 runtime tests and 190 VM tests pass. The two independent
event/fetch browser suites pass 30 checks across Chromium, Firefox and WebKit,
including exact wide integers, false/nil, initializer registration, duplicate
self-subscription, statement order, unsupported payload rejection/recovery,
two independent receivers, disposal, scoped child contracts and direct fetch
callbacks. All 30 VM source/test mirrors match; new payload and host-command
tests pass goosefmt. Core growth and exact artifact ceilings are recorded in
[payload budgets](PAYLOAD_BUDGETS.md).

Global publications use a FIFO snapshot of the subscriptions that exist when
each event is published. A receiver removed before its queued turn is skipped;
a receiver added during delivery starts with the next publication. Reentrant
chains stop at the active VM profile's `host_event_queue_entries` or
`host_event_queue_bytes` bound and report one source-located `mochi:error` with
the event and subscription context. Mochi clears the offending queued work;
other queued publications and later independent events can still run.
