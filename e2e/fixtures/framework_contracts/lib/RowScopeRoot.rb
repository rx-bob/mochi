class RowScopeRoot
  @tag_name = "row-scope-root"
  @rows
  @selected

  def initialize
    @rows = [
      {"id" => "a", "label" => "Alpha", "active" => false, "selected" => true},
      {"id" => "b", "label" => "Beta", "active" => true, "selected" => false}
    ]
    @selected = "none"
  end

  def choose(id, index)
    @selected = id + ":" + index.to_s
  end

  def activate
    @rows = [
      {"id" => "a", "label" => "Alpha", "active" => true, "selected" => true},
      @rows[1]
    ]
  end

  def reorder
    @rows = [@rows[1], @rows[0]]
  end

  def replace
    @rows = [
      {"id" => "c", "label" => "Gamma", "active" => true, "selected" => true}
    ]
  end

  def suffix
    "!"
  end

  def row_title(id)
    "row-" + id
  end

  def html
    %Q{
      <p class="selected">{@selected}</p>
      <button class="activate" onclick="{activate}">Activate</button>
      <button class="reorder" onclick="{reorder}">Reorder</button>
      <button class="replace" onclick="{replace}">Replace</button>
      {each @rows as row, index, key: row["id"]}
        <button class="row {if row['active']}active{else}inactive{end}"
                onclick="{choose(row["id"], index)}" data-row="{row["id"]}"
                title="{row_title(row["id"])}">
          {row["label"]}{suffix}
        </button>
        <span data-row="{row["id"]}" class={{"selected" => row["selected"], "zero" => index == 0}}></span>
      {end}
    }
  end
end
