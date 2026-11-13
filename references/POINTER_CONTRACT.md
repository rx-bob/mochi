# Pointer events and capture

Pointer event handlers receive a Ruby hash with `pointer_id`, `pointer_type`, `is_primary`, and `buttons`, alongside the normal event coordinates and target metadata. Pointer fields use neutral defaults when the browser event does not provide them. `gotpointercapture` and `lostpointercapture` can be handled like other declared DOM events.

Use `MochiPointer.capture(pointer_id)` in a pointer handler to keep subsequent events directed to that handler's target. Pass a named component ref to capture a different owned element: `MochiPointer.capture(event["pointer_id"], :drag_handle)`. A ref is declared in component HTML with `data-mochi-ref="drag_handle"`. Ruby receives no DOM node.

Call `MochiPointer.release(pointer_id)` to release a capture owned by the current component mount. An optional named ref checks that the requested release matches the captured element. Capture is accepted only for the matching active pointer event, with a live target owned by the component. Invalid, stale, or foreign ownership is reported as a Ruby event error.

The pointer adapter is an optional capability. Components that call `MochiPointer` load it before they become ready; components that do not use the API do not request it. Captures are associated with a component mount and released when that mount is disposed.

## Ruby-authored drag

```ruby
class DragBox
  @tag_name = "drag-box"
  @x
  @y
  @pointer_id

  def initialize
    @x = 0
    @y = 0
    @pointer_id = nil
  end

  def start_drag(event)
    @pointer_id = event["pointer_id"]
    @x = event["client_x"]
    @y = event["client_y"]
    MochiPointer.capture(@pointer_id, :handle)
  end

  def move_drag(event)
    return if @pointer_id != event["pointer_id"]
    @x = event["client_x"]
    @y = event["client_y"]
  end

  def end_drag(event)
    return if @pointer_id != event["pointer_id"]
    @x = event["client_x"]
    @y = event["client_y"]
    MochiPointer.release(@pointer_id, :handle)
    @pointer_id = nil
  end

  def html
    %Q{
      <div class="surface" style="touch-action: none" onpointermove="{move_drag($event)}"
           onpointerup="{end_drag($event)}" onpointercancel="{end_drag($event)}">
        <div class="handle" data-mochi-ref="handle"
             onpointerdown="{start_drag($event)}"
             style="left: {@x}px; top: {@y}px">Drag</div>
      </div>
    }
  end
end
```

Set `touch-action: none` on the gesture surface when the application owns touch panning for that interaction. Pointer capture preserves delivery while the pointer remains in the browser viewport; browsers cannot report movement after input leaves the browser or operating-system window.
