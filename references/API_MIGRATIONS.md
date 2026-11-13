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

Global publications use a FIFO snapshot of the subscriptions that exist when
each event is published. A receiver removed before its queued turn is skipped;
a receiver added during delivery starts with the next publication. Reentrant
chains stop at the active VM profile's `host_event_queue_entries` or
`host_event_queue_bytes` bound and report one source-located `mochi:error` with
the event and subscription context. Mochi clears the offending queued work;
other queued publications and later independent events can still run.
