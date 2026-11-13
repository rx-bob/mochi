class PointerContractsRoot
  @tag_name = "pointer-contracts-root"
  @x
  @y
  @pointer_id
  @pointer_type
  @primary
  @terminal_reason
  @start_x
  @start_y
  @delta_x
  @delta_y

  def initialize
    @x = 0
    @y = 0
    @pointer_id = -1
    @pointer_type = "none"
    @primary = false
    @terminal_reason = "none"
    @start_x = 0
    @start_y = 0
    @delta_x = 0
    @delta_y = 0
  end

  def start_drag(event)
    @pointer_id = event["pointer_id"]
    @pointer_type = event["pointer_type"]
    @primary = event["is_primary"]
    @terminal_reason = ""
    @x = event["client_x"]
    @y = event["client_y"]
    @start_x = @x
    @start_y = @y
    @delta_x = 0
    @delta_y = 0
    MochiPointer.capture(@pointer_id, :handle)
  end

  def move_drag(event)
    return if event["pointer_id"] != @pointer_id
    @x = event["client_x"]
    @y = event["client_y"]
    @delta_x = @x - @start_x
    @delta_y = @y - @start_y
  end

  def finish_drag(event)
    return if @pointer_id < 0 || event["pointer_id"] != @pointer_id
    @x = event["client_x"]
    @y = event["client_y"]
    reason = event["pointer_reason"]
    MochiPointer.release(@pointer_id, :handle) if reason == "up" || reason == "cancel"
    @pointer_id = -1
    @terminal_reason = reason
  end

  def lost_drag(event)
    finish_drag(event)
  end

  def move_keyboard(event)
    if event["key"] == "ArrowLeft"
      @x = @x - 10
    elsif event["key"] == "ArrowRight"
      @x = @x + 10
    elsif event["key"] == "ArrowUp"
      @y = @y - 10
    elsif event["key"] == "ArrowDown"
      @y = @y + 10
    elsif event["key"] == "Escape"
      MochiPointer.release(@pointer_id, :handle) if @pointer_id >= 0
      @pointer_id = -1
      @terminal_reason = "keyboard_cancel"
    end
  end

  def drag_state
    @pointer_id >= 0 ? "dragging" : "idle"
  end

  def html
    %Q{
      <section class="surface" style="touch-action: none" onpointermove="{move_drag($event)}"
               onpointerup="{finish_drag($event)}" onpointercancel="{finish_drag($event)}"
               onlostpointercapture="{lost_drag($event)}">
        <button class="handle" data-mochi-ref="handle"
                onpointerdown="{start_drag($event)}"
                onkeydown="{move_keyboard($event)}">Drag</button>
        <output class="position">{@x},{@y}</output>
        <output class="delta">{@delta_x},{@delta_y}</output>
        <output class="identity">{@pointer_type}:{@pointer_id}:{@primary}</output>
        <output class="drag-state">{drag_state}</output>
        <output class="terminal">{@terminal_reason}</output>
      </section>
    }
  end
end
