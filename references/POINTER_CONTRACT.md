# Pointer events and capture

Pointer event handlers receive a Ruby hash with `pointer_id`, `pointer_type`, `is_primary`, and `buttons`, alongside the normal event coordinates and target metadata. Pointer fields use neutral defaults when the browser event does not provide them. `gotpointercapture` and `lostpointercapture` can be handled like other declared DOM events.

Use `MochiPointer.capture(pointer_id)` in a pointer handler to keep subsequent events directed to that handler's target. Pass a named component ref to capture a different owned element: `MochiPointer.capture(event["pointer_id"], :drag_handle)`. A ref is declared in component HTML with `data-mochi-ref="drag_handle"`. Ruby receives no DOM node.

`pointer_reason` is empty for ordinary pointer events and identifies terminal notifications: `"up"`, `"cancel"`, or `"lost_capture"`. A pointer-up or pointer-cancel can be followed by lost capture, so gesture cleanup must check the active pointer ID and become a no-op after the first terminal notification. Call `MochiPointer.release(pointer_id)` to release a capture owned by the current component mount. An optional named ref checks that the requested release matches the captured element. Capture is accepted only for the matching active pointer event, with a live target owned by the component. Invalid, stale, or foreign ownership is reported as a Ruby event error.

The pointer adapter is an optional capability. Components that call `MochiPointer` load it before they become ready; components that do not use the API do not request it. Captures are associated with a component mount and released when that mount or captured target is removed. Mochi coalesces high-rate `pointermove` input to the latest event per pointer per animation frame, and flushes pending movement before `pointerup`, `pointercancel`, or `lostpointercapture`.

## Ruby-authored drag

```ruby
class DragBox
  @tag_name = "drag-box"
  @x
  @y
  @pointer_id
  @terminal_reason

  def initialize
    @x = 0
    @y = 0
    @pointer_id = nil
    @terminal_reason = ""
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

  def finish_drag(event)
    return if @pointer_id != event["pointer_id"] || @pointer_id.nil?
    @x = event["client_x"]
    @y = event["client_y"]
    reason = event["pointer_reason"]
    MochiPointer.release(@pointer_id, :handle) if reason == "up" || reason == "cancel"
    @pointer_id = nil
    @terminal_reason = reason
  end

  def lost_drag(event)
    finish_drag(event)
  end

  def move_keyboard(event)
    @x = @x - 10 if event["key"] == "ArrowLeft"
    @x = @x + 10 if event["key"] == "ArrowRight"
    @y = @y - 10 if event["key"] == "ArrowUp"
    @y = @y + 10 if event["key"] == "ArrowDown"
    if event["key"] == "Escape"
      MochiPointer.release(@pointer_id, :handle) unless @pointer_id.nil?
      @pointer_id = nil
      @terminal_reason = "keyboard_cancel"
    end
  end

  def html
    %Q{
      <div class="surface" style="touch-action: none" onpointermove="{move_drag($event)}"
           onpointerup="{finish_drag($event)}" onpointercancel="{finish_drag($event)}"
           onlostpointercapture="{lost_drag($event)}">
        <div class="handle" data-mochi-ref="handle"
             onpointerdown="{start_drag($event)}"
             onkeydown="{move_keyboard($event)}"
             style="left: {@x}px; top: {@y}px">Drag</div>
      </div>
    }
  end
end
```

Button handles remain keyboard focusable: Arrow keys move the example, and Escape cancels its active gesture. Set `touch-action: none` on the gesture surface when the application owns touch panning for that interaction. Browser or tab focus loss can cancel a gesture or lose capture; handle the lifecycle event the browser reports. Pointer capture preserves delivery while the pointer remains in the browser viewport; browsers cannot report movement after input leaves the browser or operating-system window.
