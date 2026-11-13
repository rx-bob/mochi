class PointerContractsRoot
  @tag_name = "pointer-contracts-root"
  @x
  @y
  @pointer_id
  @pointer_type
  @primary

  def initialize
    @x = 0
    @y = 0
    @pointer_id = -1
    @pointer_type = "none"
    @primary = false
  end

  def start_drag(event)
    @pointer_id = event["pointer_id"]
    @pointer_type = event["pointer_type"]
    @primary = event["is_primary"]
    @x = event["client_x"]
    @y = event["client_y"]
    MochiPointer.capture(@pointer_id, :handle)
  end

  def move_drag(event)
    return if event["pointer_id"] != @pointer_id
    @x = event["client_x"]
    @y = event["client_y"]
  end

  def end_drag(event)
    return if event["pointer_id"] != @pointer_id
    @x = event["client_x"]
    @y = event["client_y"]
    MochiPointer.release(@pointer_id, :handle)
    @pointer_id = -1
  end

  def html
    %Q{
      <section class="surface" style="touch-action: none" onpointermove="{move_drag($event)}"
               onpointerup="{end_drag($event)}" onpointercancel="{end_drag($event)}">
        <button class="handle" data-mochi-ref="handle"
                onpointerdown="{start_drag($event)}">Drag</button>
        <output class="position">{@x},{@y}</output>
        <output class="identity">{@pointer_type}:{@pointer_id}:{@primary}</output>
      </section>
    }
  end
end
