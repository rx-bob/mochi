# typed: true

class MochiBenchmark
  @tag_name = "mochi-benchmark"
  @rows
  @version
  @_next_id
  @selected_id

  def initialize
    @rows = []
    @version = 0
    @_next_id = 1
    @selected_id = nil
  end

  def html
    %Q{
      <div class="container">
        <div class="header">
          <h1>Mochi Benchmark</h1>
          <div class="controls">
            <button id="run" onclick="{run}">Create 1,000 rows</button>
            <button id="runlots" onclick="{run_lots}">Create 10,000 rows</button>
            <button id="add" onclick="{add}">Append 1,000 rows</button>
            <button id="update" onclick="{update}">Update every 10th row</button>
            <button id="clear" onclick="{clear}">Clear</button>
            <button id="swaprows" onclick="{swap_rows}">Swap Rows</button>
          </div>
        </div>
        <div class="test-data">
          {each @rows as row, index, key: row["id"]}
            <div class="row-item {if row["id"] == @selected_id}danger{end}" data-testid="row">
              <span class="col-id">{row["id"]}</span>
              <span class="col-label"><a class="lbl" data-id="{row["id"]}" onclick="{select_row($event)}">{row["label"]}</a></span>
              <span class="col-remove"><a class="remove" data-id="{row["id"]}" aria-label="remove" onclick="{remove_row_by_event($event)}">&#x2715;</a></span>
            </div>
          {end}
        </div>
      </div>
    }
  end

  def css
    %Q{
      .container {
        max-width: 800px;
        margin: 0 auto;
        font-family: sans-serif;
      }
      .header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 10px 0;
        border-bottom: 1px solid #ccc;
        margin-bottom: 10px;
      }
      h1 {
        margin: 0;
        font-size: 1.2em;
      }
      .controls {
        display: flex;
        flex-wrap: wrap;
        gap: 6px;
      }
      button {
        padding: 6px 12px;
        border: 1px solid #ccc;
        border-radius: 4px;
        cursor: pointer;
        background: #f8f9fa;
        font-size: 0.85em;
      }
      button:hover {
        background: #e2e6ea;
      }
      .row-item {
        display: flex;
        align-items: center;
        padding: 4px 0;
        border-bottom: 1px solid #f0f0f0;
      }
      .row-item.danger {
        background-color: #d9534f;
        color: #fff;
      }
      .row-item.danger a {
        color: #fff;
      }
      .col-id {
        width: 60px;
        text-align: right;
        padding-right: 10px;
        color: #666;
        font-size: 0.85em;
      }
      .col-label {
        flex: 1;
      }
      .col-label a.lbl {
        text-decoration: none;
        color: #333;
        cursor: pointer;
      }
      .col-label a.lbl:hover {
        text-decoration: underline;
      }
      .col-remove a.remove {
        cursor: pointer;
        color: #999;
        padding: 0 8px;
        text-decoration: none;
      }
      .col-remove a.remove:hover {
        color: #d9534f;
      }
    }
  end

  def mounted
  end

  def unmounted
  end

  def select_row(event)
    dataset = event["current_target_dataset"]
    @selected_id = dataset["id"].to_i
  end

  def remove_row_by_event(event)
    dataset = event["current_target_dataset"]
    remove_row(dataset["id"].to_i)
  end

  def run
    @rows = make_rows(1000)
    @_next_id = @_next_id + 1000
    @version = @version + 1
  end

  def run_lots
    @rows = make_rows(10000)
    @_next_id = @_next_id + 10000
    @version = @version + 1
  end

  def add
    new_rows = make_rows(1000)
    @_next_id = @_next_id + 1000
    rows = []
    @rows.each { |row| rows.push(row) }
    new_rows.each { |row| rows.push(row) }
    @rows = rows
    @version = @version + 1
  end

  def update
    rows = []
    index = 0
    next_update = 0
    while index < @rows.length
      row = @rows[index]
      if index == next_update
        rows.push({"id" => row["id"], "label" => row["label"] + " !!!"})
        next_update = next_update + 10
      else
        rows.push(row)
      end
      index = index + 1
    end
    @rows = rows
    @version = @version + 1
  end

  def clear
    @rows = []
    @_next_id = 1
    @selected_id = nil
    @version = @version + 1
  end

  def swap_rows
    if @rows.length >= 999
      rows = []
      @rows.each { |row| rows.push(row) }
      temporary = rows[1]
      rows[1] = rows[998]
      rows[998] = temporary
      @rows = rows
    end
    @version = @version + 1
  end

  def remove_row(id)
    rows = []
    @rows.each do |row|
      rows.push(row) if row["id"] != id
    end
    @rows = rows
    @selected_id = nil if @selected_id == id
    @version = @version + 1
  end

  private

  def make_rows(count)
    start_id = @_next_id
    rows = []
    index = 0
    while index < count
      id = start_id + index
      rows.push({"id" => id, "label" => "row #{id}"})
      index = index + 1
    end
    rows
  end
end
