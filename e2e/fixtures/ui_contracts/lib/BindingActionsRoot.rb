class BindingActionsRoot
  @tag_name = "binding-actions-root"
  @draft
  @enabled
  @project
  @seen
  @calls
  @rows
  @open

  def initialize
    @draft = "start"
    @enabled = false
    @project = "a"
    @seen = "initial"
    @calls = 0
    @rows = ["a", "b"]
    @open = true
  end

  def observe(value)
    @seen = "#{value}:#{@draft}"
    @calls += 1
  end

  def check
    @seen = @enabled ? "checked" : "unchecked"
    @calls += 1
  end

  def change(event)
    @seen = "#{@project}:#{event['value']}"
    @calls += 1
  end

  def row_changed(row, index, value)
    @seen = "#{row}:#{index}:#{value}:#{@draft}"
    @calls += 1
  end

  def reorder
    @rows = [@rows[1], @rows[0]]
  end

  def toggle
    @open = !@open
  end

  def reset
    @draft = "reset"
    @enabled = false
    @project = "a"
  end

  def html
    %Q{
      <input class="first" bind:value="{@draft}" oninput="{observe(@draft)}">
      <input class="last" oninput="{observe(@draft)}" bind:value="{@draft}">
      <input class="check-first" type="checkbox" bind:checked="{@enabled}" onchange="{check}">
      <input class="check-last" type="checkbox" onchange="{check}" bind:checked="{@enabled}">
      <select class="select-first" bind:value="{@project}" onchange="{change}"><option value="a">A</option><option value="b">B</option></select>
      <select class="select-last" onchange="{change($event)}" bind:value="{@project}"><option value="a">A</option><option value="b">B</option></select>
      {if @open}
        <input class="branch" bind:value="{@draft}" oninput="{observe(@draft)}">
        {each @rows as row, idx, key: row}
          <div class="row" data-id="{row}">
            <input class="row-draft" bind:value="{@draft}" oninput="{row_changed(row, idx, @draft)}">
            {if @open}
              <input class="row-check" onchange="{check}" type="checkbox" bind:checked="{@enabled}">
              <select class="row-select" onchange="{change}" bind:value="{@project}"><option value="a">A</option><option value="b">B</option></select>
            {end}
          </div>
        {end}
      {end}
      <output class="seen">{@seen}</output><output class="calls">{@calls}</output>
      <button class="reorder" onclick="{reorder}">Reorder</button>
      <button class="toggle" onclick="{toggle}">Toggle</button>
      <button class="reset" onclick="{reset}">Reset</button>
    }
  end
end
