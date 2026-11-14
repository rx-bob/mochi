# Optional layout measurement

`MochiLayout` is an optional Ruby package with an owned browser adapter. A
component or reachable helper that calls it adds the package and capability;
the adapter downloads when that component first mounts. Unused applications
omit both. No application JavaScript or manual script tag is needed.

```ruby
def mounted
  MochiLayout.observe("viewport", "on_size")
end

def fit
  MochiLayout.measure("viewport", "on_size")
end

def on_size(result)
  if result["ok"]
    geometry = result["value"]
    @width = geometry["width"]
    @height = geometry["height"]
  else
    @error = result["error"]
  end
end

def stop
  MochiLayout.cancel("viewport")
end
```

The template declares a unique static `ref="viewport"` in the owning component.
Callbacks name component methods and receive the existing host envelope:
`{"ok" => true, "value" => geometry, "error" => nil}` or an error envelope with
`ok: false`, `value: nil`, and a readable error string. Missing/disconnected
refs, invalid arguments, unavailable ResizeObserver, and exhausted capacity
report errors. `cancel` needs no callback and is harmless when nothing matches.

## Geometry and delivery

Geometry contains numeric `x`, `y`, `width`, `height`, `top`, `right`, `bottom`,
and `left`. These describe the axis-aligned border box from
`getBoundingClientRect`, in CSS pixels relative to the browser viewport. They
include CSS transforms, border, and padding; they are not document coordinates,
device pixels, SVG model units, or live DOM objects. Hidden boxes can return
zero dimensions. Callers must handle those before dividing or fitting.

`measure` delivers once on an animation frame. `observe` delivers an initial
measurement, then changes in width or height, using border-box resize
observation. Scrolling, position changes, and transform-only changes do not
promise notifications; use `measure` when fresh position is required.

Resize notifications coalesce into one scheduled frame. Each dirty element is
read once per batch, and all reads precede Ruby callbacks. Unchanged dimensions
are suppressed. A callback that writes a new size can schedule another frame;
applications should avoid resize feedback loops.

## Ownership and bounds

Ownership includes the component instance and its mount generation. Explicit
`cancel(ref)` cancels pending measurements and the observation for that ref.
`observe` replaces existing work for the same owner/ref. Unmount disconnects
observers and cancels queued reads. Removed or replaced ref targets stop their
old observation; observe the new target explicitly. Stale callbacks cannot
reach a new mount, even when its VM instance number is reused.

The adapter limits active observations plus queued measurements to the existing
capacity profile's `bindings` count (`layout.limits.requests`, default 2,048).
Completion or cancellation releases the slot. No new VM arena or capacity
default is introduced. Row-local refs, arbitrary DOM traversal, and dynamic
per-node measurement remain deferred.

## Graph fixture

The graph observes its static viewport. **Fit graph** enables fitting to its
actual measured dimensions with 24 CSS pixels of padding. Ruby computes model
bounds for circles and the fixture's fixed monospace labels. Later size changes
refit; captured dragging divides pointer deltas by the fit scale. A fit or size
change cancels an active gesture before changing coordinates.

Zero dimensions report `hidden` and retain the last usable viewBox. A viewport
at most 48 pixels in either dimension reports `too small` without division.
An empty visible graph reports `empty` with identity scale and zero translation.
**Stop resize observation** cancels future resize delivery; explicit fitting
still measures once. Viewport fit state stays outside model undo history.

Adapter tests cover geometry, batching, cancellation during delivery, capacity
reuse, missing/replaced refs, and stale mounts. Loader tests cover generation
guards and owned cleanup. Browser checks resize the real graph, assert padded
containment and scaled dragging, exercise hidden/zero/empty states, and verify
optional package omission and one-time lazy loading across all three browsers.
