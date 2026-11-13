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

  def move_node
    @nodes = @nodes.map do |node|
      if node["id"] == "b"
        {"id" => node["id"], "label" => node["label"], "x" => node["x"] + 20,
         "y" => node["y"] + 10, "radius" => node["radius"] + 1}
      else
        node
      end
    end
  end

  def reorder_edges
    @reversed = !@reversed
    order_edges
  end

  def order_edges
    @edges = @edges.sort_by { |item| @reversed ? -item["order"] : item["order"] }
  end

  def remove_edge
    @edges = @edges.reject { |item| item["id"] == "bc" }
  end

  def restore_edge
    remove_edge
    @edges = @edges + [edge("bc", "b", "c", 2)]
    order_edges
  end

  def pan
    @offset_x += 10
    @offset_y += 5
  end

  def toggle
    @open = !@open
  end

  def html
    %Q{
      <h1>Editable graph</h1>
      <p><span class="node-count">{@nodes.length}</span> nodes; <span class="edge-count">{@edges.length}</span> edges</p>
      <button class="move" onclick="{move_node}">Move Review</button>
      <button class="reorder" onclick="{reorder_edges}">Reverse edges</button>
      <button class="remove" onclick="{remove_edge}">Remove middle edge</button>
      <button class="restore" onclick="{restore_edge}">Restore middle edge</button>
      <button class="pan" onclick="{pan}">Pan graph</button>
      <button class="toggle" onclick="{toggle}">Toggle graph</button>
      {if @open}
        <svg class="canvas" viewBox="0 0 {@width} {@height}" width="400" height="220" role="img" aria-label="Four-node workflow">
          <defs><marker id="arrowhead" viewBox="0 0 8 8" refX="{@arrow_size}" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 8 4 L 0 8 Z" fill="currentColor"></path></marker></defs>
          <g class="scene" transform="translate({@offset_x} {@offset_y})">
            <g class="edges" fill="none" stroke="currentColor" stroke-width="2">
              {each @edges as item, key: item["id"]}
                <path class="edge" data-edge="{item['id']}" d="{edge_path(item)}" marker-end="url(#arrowhead)"></path>
              {end}
            </g>
            <g class="nodes">
              {each @nodes as node, key: node["id"]}
                <g class="node" data-node="{node['id']}" transform="translate({node['x']} {node['y']})">
                  <circle r="{node['radius']}" fill="white" stroke="currentColor"></circle>
                  <text x="18" y="4">{node["label"]}</text>
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
