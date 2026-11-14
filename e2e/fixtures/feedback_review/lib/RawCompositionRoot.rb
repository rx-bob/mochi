class RawCompositionRoot
  @tag_name = "raw-composition-root"
  @rows
  @version
  @show_rows
  @selected

  def initialize
    @rows = [
      {"id" => "a", "label" => "Alpha", "meta" => {"value" => "A"}, "markup" => '<i class="row-mark">A</i>'},
      {"id" => "b", "label" => "Beta", "meta" => {"value" => "B"}, "markup" => '<i class="row-mark">B</i>'}
    ]
    @version = 0
    @show_rows = true
    @selected = "none"
    @user_text = '<img class="untrusted" src=x onerror="bad()">'
  end

  def update_raw
    if @version == 0
      @version = 1
    elsif @version == 1
      @version = 2
    else
      @version = 1
    end
  end

  def toggle_rows
    @show_rows = !@show_rows
  end

  def reorder
    @rows = [@rows[1], @rows[0]]
  end

  def receive(payload)
    @selected = payload["value"]
  end

  def fragment
    if @version == 1
      '<svg class="icon" viewBox="0 0 8 8"><circle cx="4" cy="4" r="3"></circle></svg><strong class="badge">{not_a_binding}</strong>'
    elsif @version == 2
      ""
    else
      '<svg class="icon" viewBox="0 0 8 8"><circle cx="4" cy="4" r="2"></circle></svg>'
    end
  end

  def table_fragment
    '<b class="table-value">table</b><em>context</em>'
  end

  def html
    %Q{
      <main>
        <button class="update-raw" onclick="{update_raw}">Update raw</button>
        <button class="toggle-rows" onclick="{toggle_rows}">Toggle rows</button>
        <button class="reorder" onclick="{reorder}">Reorder</button>
        <output class="selected">{@selected}</output>
        <p class="user-label">{@user_text}</p>
        <div class="raw-mixed">Before {Mochi.raw(fragment)} after</div>
        <table><tbody><tr><td class="raw-cell">{Mochi.raw(table_fragment)}</td></tr></tbody></table>
        {if @show_rows}
          {each @rows as row, key: row["id"]}
            <article class="row" data-row="{row["id"]}">
              <input class="draft">
              {Mochi.raw(row["markup"])}
              <review-child label="{row["label"]}" meta="{row["meta"]}" on:action="{receive($event)}"></review-child>
            </article>
          {end}
        {end}
      </main>
    }
  end

  def css
    %Q{.raw-mixed { display: flex; align-items: center; gap: 4px; } .row { display: grid; grid-template-columns: 1fr auto; }}
  end
end
