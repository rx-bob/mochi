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

Choose a stable `ref` whose element exists in the owning component's template.
Mount that owner before observing it. A lazy descendant can load later and
change the observed element's size; the initial measurement does not wait for
descendant descriptors, packages, or styles. In a Ruby behavior test, use
`wait_for("panel-host")` when the next action needs that named child to be
interactive. Readiness does not promise a final layout: respond to observed
size changes instead of sleeping for a fixed interval or assuming that two
animation frames finish all descendant styling.

For example, a drawing surface can place a marker at its own measured center.
If a side panel appears, disappears, or the container resizes, the observed
surface reports its new dimensions and Ruby derives the next coordinates from
those dimensions:

```ruby
def mounted
  MochiLayout.observe("canvas", "on_canvas_size")
end

def on_canvas_size(result)
  unless result["ok"]
    @layout_error = result["error"]
    return
  end

  geometry = result["value"]
  return if geometry["width"] <= 0 || geometry["height"] <= 0

  @marker_x = geometry["width"] / 2.0
  @marker_y = geometry["height"] / 2.0
end
```

The coordinates above are local to the measured surface. They do not depend on
the panel's assumed width or a reserved CSS class. Render the canvas and its
`ref="canvas"` in the owning component; the ref is not a descendant-load
barrier.

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
