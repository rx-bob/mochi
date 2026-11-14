# Wheel events and graph zoom

Ruby wheel handlers receive `delta_x`, `delta_y`, `delta_z`, and `delta_mode`
alongside the normal client coordinates, modifiers, and target metadata.
Missing fields default to zero. Deltas retain their browser units:

| Mode | Unit |
| --- | --- |
| 0 | CSS pixels |
| 1 | Lines |
| 2 | Pages |

Mochi does not silently convert these fields. Declare scroll prevention in the
template, so it runs synchronously before queued Ruby work:

```ruby
def html
  %Q{<div onwheel.prevent="{zoom($event)}">Zoom region</div>}
end
```

Existing `.stop` and `.self` modifiers also apply. Modifiers are evaluated once
in the native listener, before browser shadow retargeting. A plain `onwheel`
does not prevent scrolling. Non-passive listeners attach to actual declared
wheel regions; events outside those regions retain normal browser behavior.
Nested regions deliver to the nearest declared handler.

## Coalescing and ownership

Each mounted component queues one animation frame for wheel input. Each bound
target has three fixed buckets, one per native mode. Deltas X/Y/Z are summed
within their own unit; unlike units are never added together. At most three
Ruby payloads per target are delivered per frame, in pixel/line/page order,
using the latest event's anchor, modifiers, and target metadata for that target.
Unknown synthetic modes pass through without creating extra buckets.

No geometry is read per native wheel event. Listeners follow conditional and
keyed target insertion/removal. Unmount removes listeners and cancels queued
frames. Delivery checks mount generation and current target ownership again
before entering Ruby; a detached target or a reused mount cannot receive old
work. These are ordinary event facilities, with no new host adapter, VM arena,
capacity default, or application JavaScript requirement.

## Graph conversion and anchor policy

The graph uses vertical delta only. It accumulates pixel, line, and page deltas
behind one pending `MochiLayout.measure("viewport", ...)` request. At delivery:

```
pixels = pixel_delta + line_delta * 16 + page_delta * measured_height
new_scale = clamp(old_scale - pixels / 500, 0.25, 4)
anchor = latest_client_position - measured_viewport_origin
model_point = (anchor - old_translation) / old_scale
new_translation = anchor - model_point * new_scale
```

Positive Y zooms out; negative Y zooms in. Horizontal/Z-only input does not
zoom. Latest nonzero vertical input supplies the anchor, including input that
arrives while measurement is pending. Zero/hidden geometry drops the batch
without division. A fresh measurement handles page scrolling and position
changes that resize observation alone does not report.

The fixture's viewport has no border, padding, or CSS transform, and its SVG
viewBox tracks measured dimensions. Client deltas divided by scale therefore
remain correct for dragging. Fit and zoom remain outside model undo history.
Manual zoom disables automatic fit. Wheel input cancels an existing drag;
a new drag discards pending zoom. Fit, closing the graph, explicit layout
cancellation, and unmount also clear pending zoom intent.

Browser tests require the graph point under the actual event coordinates to
stay within **0.02 CSS pixels**. They cover all modes, accumulated mixed-mode
bursts with one geometry read, both scale limits, native scroll prevention,
scrolling outside the graph, and dragging after zoom or during a pending read.
Loader tests cover neutral fields, `.self` with composed events, target removal,
cross-root movement, cancellation, and remount without duplicate listeners.
