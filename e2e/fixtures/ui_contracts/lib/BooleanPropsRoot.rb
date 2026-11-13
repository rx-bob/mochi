class BooleanPropsRoot
  @tag_name = "boolean-props-root"
  @open
  @disabled
  def initialize
    @open = true
    @disabled = true
  end
  def toggle
    @open = !@open
  end
  def enable
    @disabled = false
  end
  def html
    %Q{
      <field-editor class="static" field_id="static" label="Static optional" initial_value="" required="false"></field-editor>
      {if @open}
        <field-editor class="conditional" field_id="conditional" label="Conditional required" initial_value="Hello" required="true" disabled="{@disabled}"></field-editor>
      {end}
      <button class="toggle" onclick="{toggle}">Toggle</button>
      <button class="enable" onclick="{enable}">Enable</button>
    }
  end
end
