class ConditionalRoot
  @tag_name = "conditional-root"
  @open
  @nested

  def initialize
    @open = false
    @nested = false
  end

  def toggle
    @open = !@open
    @nested = !@nested
  end

  def html
    %Q{
      <!-- root conditional follows -->
      {if @open}
        <button class="toggle" onclick="{toggle}">Toggle</button>
        <p class="visible">Visible</p>
        {if @nested}
          <span class="nested">Nested</span>
        {else}
          <span class="nested">Plain</span>
        {end}
      {else}
        <button class="toggle" onclick="{toggle}">Toggle</button>
        <p class="hidden">Hidden</p>
      {end}
      <!-- root conditional ends -->
    }
  end
end

class InitiallyOpenConditional
  @tag_name = "initially-open-conditional"
  @open

  def initialize
    @open = true
  end

  def html
    %Q{
      {if @open}
        <p class="visible">Initially visible</p>
      {else}
        <p class="hidden">Hidden</p>
      {end}
    }
  end
end
