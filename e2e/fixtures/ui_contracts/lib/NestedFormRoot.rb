class NestedFormRoot
  @tag_name = "nested-form-root"
  prop :open, Boolean, default: true
  @groups
  @last
  @events
  @quoted
  @saved
  @cancelled
  @focus_return
  @shortcut_error

  def initialize
    @groups = [
      {"id" => "g1", "label" => "Identity", "enabled" => true, "fields" => [
        field("a", "Name", "Alpha", true, false),
        field("b", "Alias", "Beta", false, true)
      ]},
      {"id" => "g2", "label" => "Contact", "enabled" => true, "fields" => [
        field("c", "City", "Gamma", true, true),
        field("d", "Country", "Delta", false, false)
      ]}
    ]
    @saved = "none"
    @cancelled = false
    @focus_return = false
    @shortcut_error = ""
    @last = "none"
    @events = 0
    @quoted = {"label" => "Quoted title", "active" => true}
  end

  def mounted
    MochiShortcuts.register("Escape", "shortcut_cancel",
      {"scope" => "application", "active_ref" => "dialog", "prevent" => true, "allow_editable" => true})
  end

  def shortcut_cancel(result)
    if result["ok"]
      @cancelled = true
      close_form
    else
      @shortcut_error = result["error"]
    end
  end

  # mochi-lint: disable-next components/prop-write -- fixture proves host attribute updates and local dialog controls share one open state
  def close_form
    @open = false
    if @focus_return
      Mochi.restore_focus
    else
      Mochi.focus("toggle")
    end
    @focus_return = false
  end

  def field(id, label, value, help, invalid)
    {"id" => id, "label" => label, "value" => value, "help" => help, "invalid" => invalid}
  end

  def group_copy(group, fields, enabled)
    {"id" => group["id"], "label" => group["label"], "fields" => fields, "enabled" => enabled}
  end

  # mochi-lint: disable-next components/prop-write -- fixture proves host attribute updates and local dialog controls share one open state
  def toggle
    if @open
      close_form
    else
      @open = true
      Mochi.focus("dialog")
      @focus_return = true
    end
  end

  def reorder
    @groups = [@groups[1], @groups[0]]
  end

  def reorder_fields
    @groups = @groups.map do |group|
      fields = group["fields"]
      group["id"] == "g1" ? group_copy(group, [fields[1], fields[0]], group["enabled"]) : group
    end
  end

  def insert_neighbor
    @groups = @groups.map do |group|
      if group["id"] == "g1"
        fields = [field("x", "Neighbor", "Extra", false, false)] + group["fields"]
        group_copy(group, fields, group["enabled"])
      else
        group
      end
    end
  end

  def remove_neighbor
    @groups = @groups.map do |group|
      group_copy(group, group["fields"].reject { |item| item["id"] == "x" }, group["enabled"])
    end
  end

  def toggle_group
    @groups = @groups.map do |group|
      group["id"] == "g1" ? group_copy(group, group["fields"], !group["enabled"]) : group
    end
  end

  def fresh_values
    @groups = @groups.map do |group|
      fields = group["fields"].map do |item|
        field(item["id"], item["label"], "Fresh #{item['id']}", item["help"], item["invalid"])
      end
      group_copy(group, fields, group["enabled"])
    end
  end

  def record_edit(group_id, field_id, group_index, field_index, event)
    @events += 1
    @last = "#{group_id}:#{field_id}:#{group_index}:#{field_index}:#{event['value']}"
  end

  def record_save(group_id, field_id, event)
    @groups = @groups.map do |group|
      fields = group["fields"].map do |item|
        if group["id"] == group_id && item["id"] == field_id
          field(item["id"], item["label"], event["value"], item["help"], item["invalid"])
        else
          item
        end
      end
      group_copy(group, fields, group["enabled"])
    end
    @saved = "#{field_id}:#{event['value']}:#{event['valid']}"
  end

  def cancel_form(event)
    @cancelled = event["discarded"]
    close_form
  end

  def pick(group_id, field_id, group_index, field_index)
    @events += 1
    @last = "#{group_id}:#{field_id}:#{group_index}:#{field_index}:picked"
  end

  def adversarial_labels
    label = %q(Label "' <img data-injected='yes'> & &quot; {end})
    @quoted = {"label" => label, "active" => true}
    @groups = @groups.map do |group|
      fields = group["fields"].map do |item|
        field(item["id"], label, item["value"], item["help"], item["invalid"])
      end
      group_copy(group, fields, group["enabled"])
    end
  end

  def quote_event(value)
    @last = value
  end

  # mochi-lint: disable-next metrics/html-method-length -- fixture keeps the complete nested form markup in one component to prove keyed row identity and focus behavior
  def html
    %Q{
      <h1>Nested form</h1>
      <output class="shortcut-error">{@shortcut_error}</output>
      <button class="adversarial" onclick="{adversarial_labels}">Use quoted labels</button>
      <p class="quoted-static" title="{@quoted["label"]}" data-alt='{@quoted['label']}' data-interpolated="{"#{@quoted["label"]}:#{%q[}]}"}" data-literal="{{literal}}">{@quoted["label"]}</p>
      <button class="quoted-event" onclick="{quote_event("#{@quoted["label"]}:#{%q[}]}")}">Read quoted title</button>
      <button class="quoted-escape" onclick="{quote_event("quote: \"x\"")}">Read escaped quotes</button>
      <button ref="toggle" class="toggle" onclick="{toggle}">Toggle form</button>
      <button class="reorder" onclick="{reorder}">Reorder groups</button>
      <button class="reorder-fields" onclick="{reorder_fields}">Reorder fields</button>
      <button class="insert" onclick="{insert_neighbor}">Insert neighbor</button>
      <button class="remove" onclick="{remove_neighbor}">Remove neighbor</button>
      <button class="toggle-group" onclick="{toggle_group}">Toggle identity group</button>
      <button class="fresh" onclick="{fresh_values}">Fresh values</button>
      <output class="saved">{@saved}</output><output class="cancelled">{@cancelled}</output>
      <output class="last">{@last}</output><output class="events">{@events}</output>
      {if @open}
        <section ref="dialog" class="dialog" role="dialog" aria-modal="true" aria-label="Nested form" tabindex="-1" data-mochi-focus-trap>
          <p class="quoted-branch {if @quoted["active"]}active{end}" title="{@quoted["label"]}" data-entity="{if @quoted["active"]}&quot; {@quoted["label"]} &amp;{else}none{end}">{@quoted['label']}</p>
          <div class="groups">
            {each @groups as group, gi, key: group["id"]}
              <section class="group" data-group="{group['id']}" data-index="{gi}">
                <h2>{group["label"]}</h2>
                {if group["enabled"]}
                  <div class="fields">
                    {each group["fields"] as item, fi, key: item["id"]}
                      <div class="field" data-field="{item['id']}" data-index="{fi}" title="{item["label"]}" data-alt=' {item['label']} ' data-literal="{{row}}" data-entity="{if item["help"]}&quot; {item["label"]} &amp;{else}plain{end}">
                        <field-editor required="{item['help']}" disabled="{item['id'] == 'd'}" on:save="{record_save(group['id'], item['id'], $event)}" on:cancel="{cancel_form($event)}" field_id="{item["id"]}" label="{group["label"]} / {item['label']}" initial_value="{item["value"]}" on:edit="{record_edit(group["id"], item["id"], gi, fi, $event)}"></field-editor>
                        <button class="quoted-row-event" onclick="{quote_event("#{group["label"]}|#{item["label"]}")}">Read field label</button>
                        {if item["help"]}
                          <aside class="help" data-for="{group['id']}:{item['id']}">
                            <button class="pick" title="{item["label"]}" onclick="{pick(group["id"], item["id"], gi, fi)}">Help {item["label"]}</button>
                            {if item["invalid"]}
                              <span class="validation">Check {item["label"]}</span>
                            {else}
                              <span class="valid">Ready</span>
                            {end}
                          </aside>
                        {elsif item["invalid"]}
                          <p class="validation">Required {item["label"]}</p>
                        {else}
                          <p class="quiet">Optional {item["label"]}</p>
                        {end}
                      </div>
                    {end}
                  </div>
                {else}
                  <p class="group-disabled">Disabled {group["label"]}</p>
                {end}
              </section>
            {end}
          </div>
        </section>
      {else}
        <p class="closed">Form closed</p>
      {end}
    }
  end
end
