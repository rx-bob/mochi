class ContextRowsRoot
  @tag_name = "context-rows-root"
  @rows
  @selected

  def initialize
    @rows = [
      {"id" => "a", "label" => "Alpha", "color" => "red"},
      {"id" => "b", "label" => "Beta", "color" => "blue"}
    ]
    @selected = "none"
  end

  def choose(id)
    @selected = id
  end

  def reorder
    @rows = [@rows[1], @rows[0]]
  end

  def update
    @rows = [
      {"id" => "a", "label" => "Alpine", "color" => "green"},
      {"id" => "b", "label" => "Bravo", "color" => "purple"}
    ]
  end

  def replace
    @rows = [
      @rows[1],
      {"id" => "c", "label" => "Charlie", "color" => "orange"}
    ]
  end

  def html
    %Q{
      <button class="reorder" onclick="{reorder}">Reorder</button>
      <button class="update" onclick="{update}">Update</button>
      <button class="replace" onclick="{replace}">Replace</button>
      <p class="selected">{@selected}</p>
      <table class="rows">
        <thead><tr><th>Record</th><th>Draft</th><th>Action</th></tr></thead>
        <tbody>
          {each @rows as row, key: row["id"]}
            <tr data-row="{row["id"]}">
              <td class="label">{row["label"]}</td>
              <td><input class="draft" value="{row["label"]}"></td>
              <td><button class="choose" onclick="{choose(row["id"])}">{row["id"]}</button></td>
            </tr>
          {end}
        </tbody>
      </table>
      <select class="options">
        {each @rows as row, key: row["id"]}
          <option value="{row["id"]}">{row["label"]}</option>
        {end}
      </select>
      <svg class="icons" viewBox="0 0 10 10">
        <g class="paths">
          {each @rows as row, key: row["id"]}
            <path data-row="{row["id"]}" fill="{row["color"]}" d="M0 0h1v1z"></path>
          {end}
        </g>
      </svg>
    }
  end
end
