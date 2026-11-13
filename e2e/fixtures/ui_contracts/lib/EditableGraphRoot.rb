class EditableGraphRoot
  @tag_name = "editable-graph-root"
  prop :open, Boolean, default: true
  @nodes
  @edges
  @reversed
  @offset_x
  @offset_y
  @width
  @height
  @arrow_size
  @selected_id
  @next_node_id
  @undo
  @redo
  @pointer_id
  @drag_node
  @drag_before
  @press_x
  @press_y
  @drag_x
  @drag_y
  @drag_moved
  @terminal_reason

  computed :rendered_edges, depends_on: [:@nodes, :@edges]

  def initialize
    @nodes = [
      {"id" => "a", "label" => "Start", "x" => 40, "y" => 50, "radius" => 12},
      {"id" => "b", "label" => "Review", "x" => 180, "y" => 50, "radius" => 12},
      {"id" => "c", "label" => "Approve", "x" => 180, "y" => 150, "radius" => 12},
      {"id" => "d", "label" => "Finish", "x" => 320, "y" => 150, "radius" => 12}
    ]
    @edges = [edge("ab", "a", "b", 1), edge("bc", "b", "c", 2), edge("cd", "c", "d", 3)]
    @reversed = false
    @offset_x = 0
    @offset_y = 0
    @width = 400
    @height = 220
    @arrow_size = 8
    @selected_id = ""
    @next_node_id = 1
    @undo = []
    @redo = []
    @pointer_id = -1
    @drag_node = ""
    @drag_before = nil
    @press_x = 0
    @press_y = 0
    @drag_x = 0
    @drag_y = 0
    @drag_moved = false
    @terminal_reason = ""
  end

  def edge(id, from, to, order)
    {"id" => id, "from" => from, "to" => to, "order" => order}
  end

  def node_for(id)
    found = nil
    @nodes.each do |node|
      found = node if node["id"] == id
    end
    found
  end

  def edge_path(edge)
    from = node_for(edge["from"])
    to = node_for(edge["to"])
    "M #{from['x']} #{from['y']} L #{to['x']} #{to['y']}"
  end

  def rendered_edges
    @edges.map { |item| {"id" => item["id"], "path" => edge_path(item)} }
  end

  def select_node(event)
    @selected_id = event["current_target_dataset"]["node"]
  end

  # Snapshots own their arrays and hashes. Strings are only ever replaced.
  def copy_nodes(nodes)
    nodes.map do |node|
      {"id" => node["id"], "label" => node["label"], "x" => node["x"],
       "y" => node["y"], "radius" => node["radius"]}
    end
  end

  def copy_edges(edges)
    edges.map { |item| edge(item["id"], item["from"], item["to"], item["order"]) }
  end

  def snapshot
    {"nodes" => copy_nodes(@nodes), "edges" => copy_edges(@edges),
     "selected" => @selected_id, "next_id" => @next_node_id, "reversed" => @reversed}
  end

  def restore_snapshot(saved)
    @nodes = copy_nodes(saved["nodes"])
    @edges = copy_edges(saved["edges"])
    @selected_id = saved["selected"]
    @next_node_id = saved["next_id"]
    @reversed = saved["reversed"]
  end

  def record_edit(before)
    @undo = @undo + [before]
    @undo = @undo.slice(@undo.length - 40, 40) if @undo.length > 40
    @redo = []
  end

  def undo_change
    cancel_gesture("undo")
    return if @undo.empty?
    saved = @undo[-1]
    @undo = @undo.slice(0, @undo.length - 1)
    @redo = @redo + [snapshot]
    restore_snapshot(saved)
  end

  def redo_change
    cancel_gesture("redo")
    return if @redo.empty?
    saved = @redo[-1]
    @redo = @redo.slice(0, @redo.length - 1)
    @undo = @undo + [snapshot]
    restore_snapshot(saved)
  end

  def move_node
    cancel_gesture("edit")
    return if node_for("b").nil?
    before = snapshot
    @nodes = @nodes.map do |node|
      if node["id"] == "b"
        {"id" => node["id"], "label" => node["label"], "x" => node["x"] + 20,
         "y" => node["y"] + 10, "radius" => node["radius"] + 1}
      else
        node
      end
    end
    record_edit(before)
  end

  def add_node
    cancel_gesture("edit")
    before = snapshot
    id = "n#{@next_node_id}"
    @nodes = @nodes + [{"id" => id, "label" => "Node #{@next_node_id}",
                        "x" => 40, "y" => 180, "radius" => 12}]
    @next_node_id += 1
    @selected_id = id
    record_edit(before)
  end

  def remove_node
    cancel_gesture("edit")
    return if node_for(@selected_id).nil?
    before = snapshot
    id = @selected_id
    @nodes = @nodes.reject { |node| node["id"] == id }
    @edges = @edges.reject { |item| item["from"] == id || item["to"] == id }
    @selected_id = ""
    record_edit(before)
  end

  def reorder_edges
    cancel_gesture("edit")
    before = snapshot
    @reversed = !@reversed
    order_edges
    record_edit(before)
  end

  def order_edges
    @edges = @edges.sort_by { |item| @reversed ? -item["order"] : item["order"] }
  end

  def remove_edge
    cancel_gesture("edit")
    remaining = @edges.reject { |item| item["id"] == "bc" }
    return if remaining.length == @edges.length
    before = snapshot
    @edges = remaining
    record_edit(before)
  end

  def restore_edge
    cancel_gesture("edit")
    return if node_for("b").nil? || node_for("c").nil?
    remaining = @edges.reject { |item| item["id"] == "bc" }
    return if remaining.length != @edges.length
    before = snapshot
    @edges = @edges + [edge("bc", "b", "c", 2)]
    order_edges
    record_edit(before)
  end

  def start_drag(event)
    return if @pointer_id >= 0 || event["button"] != 0 || !event["is_primary"]
    id = event["current_target_dataset"]["node"]
    node = node_for(id)
    return if node.nil?
    @selected_id = id
    @drag_before = snapshot
    @drag_node = id
    @pointer_id = event["pointer_id"]
    @press_x = event["client_x"]
    @press_y = event["client_y"]
    @drag_x = node["x"]
    @drag_y = node["y"]
    @drag_moved = false
    @terminal_reason = ""
    MochiPointer.capture(@pointer_id)
  end

  def move_drag(event)
    return if @pointer_id < 0 || event["pointer_id"] != @pointer_id
    x = @drag_x + event["client_x"] - @press_x
    y = @drag_y + event["client_y"] - @press_y
    @drag_moved = x != @drag_x || y != @drag_y
    @nodes = @nodes.map do |node|
      if node["id"] == @drag_node
        {"id" => node["id"], "label" => node["label"], "x" => x,
         "y" => y, "radius" => node["radius"]}
      else
        node
      end
    end
  end

  def finish_drag(event)
    return if @pointer_id < 0 || event["pointer_id"] != @pointer_id
    reason = event["pointer_reason"]
    id = @pointer_id
    if reason == "up"
      move_drag(event)
      record_edit(@drag_before) if @drag_moved
    else
      restore_snapshot(@drag_before)
    end
    clear_gesture(reason)
    MochiPointer.release(id) if reason == "up" || reason == "cancel"
  end

  def clear_gesture(reason)
    @pointer_id = -1
    @drag_node = ""
    @drag_before = nil
    @drag_moved = false
    @terminal_reason = reason
  end

  def cancel_gesture(reason)
    return if @pointer_id < 0
    id = @pointer_id
    restore_snapshot(@drag_before)
    clear_gesture(reason)
    MochiPointer.release(id)
  end

  def unmounted
    # The loader releases capture before invoking this hook.
    clear_gesture("unmount")
  end

  def drag_state
    @pointer_id >= 0 ? "dragging" : "idle"
  end

  def pan
    cancel_gesture("pan")
    @offset_x += 10
    @offset_y += 5
  end

  def toggle
    cancel_gesture("closed")
    @open = !@open
  end

  def html
    %Q{
      <h1>Editable graph</h1>
      <p>Selected <span class="selected-id">{@selected_id}</span></p>
      <p><span class="node-count">{@nodes.length}</span> nodes; <span class="edge-count">{@edges.length}</span> edges</p>
      <p>Undo <span class="undo-count">{@undo.length}</span>; redo <span class="redo-count">{@redo.length}</span></p>
      <p class="drag-state">{drag_state}</p><p class="terminal">{@terminal_reason}</p>
      <button class="add-node" onclick="{add_node}">Add node</button>
      <button class="remove-node" onclick="{remove_node}">Remove selected node</button>
      <button class="undo" onclick="{undo_change}">Undo</button>
      <button class="redo" onclick="{redo_change}">Redo</button>
      <button class="move" onclick="{move_node}">Move Review</button>
      <button class="reorder" onclick="{reorder_edges}">Reverse edges</button>
      <button class="remove" onclick="{remove_edge}">Remove middle edge</button>
      <button class="restore" onclick="{restore_edge}">Restore middle edge</button>
      <button class="pan" onclick="{pan}">Pan graph</button>
      <button class="toggle" onclick="{toggle}">Toggle graph</button>
      {if @open}
        <svg class="canvas" viewBox="0 0 {@width} {@height}" width="400" height="220" role="img" aria-label="Editable workflow" style="touch-action: none"
             onpointermove="{move_drag($event)}" onpointerup="{finish_drag($event)}"
             onpointercancel="{finish_drag($event)}" onlostpointercapture="{finish_drag($event)}">
          <defs><marker id="arrowhead" viewBox="0 0 8 8" refX="{@arrow_size}" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 8 4 L 0 8 Z" fill="currentColor"></path></marker></defs>
          <g class="scene" transform="translate({@offset_x} {@offset_y})">
            <g class="edges" fill="none" stroke="currentColor" stroke-width="2">
              {each rendered_edges as item, key: item["id"]}
                <path class="edge" data-edge="{item['id']}" d="{item['path']}" marker-end="url(#arrowhead)"></path>
              {end}
            </g>
            <g class="nodes">
              {each @nodes as node, key: node["id"]}
                <g class="node" data-node="{node['id']}" onclick="{select_node($event)}" onpointerdown="{start_drag($event)}" transform="translate({node['x']} {node['y']})">
                  <circle data-part="shape" r="{node['radius']}" fill="white" stroke="currentColor"></circle>
                  <text data-part="label" x="18" y="4">{node["label"]}</text>
                </g>
              {end}
            </g>
          </g>
        </svg>
      {else}
        <p class="closed">Graph closed</p>
      {end}
    }
  end
end
