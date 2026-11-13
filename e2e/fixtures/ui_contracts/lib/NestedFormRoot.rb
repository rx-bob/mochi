class NestedFormRoot
  @tag_name = "nested-form-root"
  prop :open, Integer, default: 1
  @groups
  @last
  @events

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
    @last = "none"
    @events = 0
  end

  def field(id, label, value, help, invalid)
    {"id" => id, "label" => label, "value" => value, "help" => help, "invalid" => invalid}
  end

  def group_copy(group, fields, enabled)
    {"id" => group["id"], "label" => group["label"], "fields" => fields, "enabled" => enabled}
  end

  def toggle
    @open = @open == 1 ? 0 : 1
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

  def pick(group_id, field_id, group_index, field_index)
    @events += 1
    @last = "#{group_id}:#{field_id}:#{group_index}:#{field_index}:picked"
  end

  def html
    %Q{
      <h1>Nested form</h1>
      <button class="toggle" onclick="{toggle}">Toggle form</button>
      <button class="reorder" onclick="{reorder}">Reorder groups</button>
      <button class="reorder-fields" onclick="{reorder_fields}">Reorder fields</button>
      <button class="insert" onclick="{insert_neighbor}">Insert neighbor</button>
      <button class="remove" onclick="{remove_neighbor}">Remove neighbor</button>
      <button class="toggle-group" onclick="{toggle_group}">Toggle identity group</button>
      <button class="fresh" onclick="{fresh_values}">Fresh values</button>
      <output class="last">{@last}</output><output class="events">{@events}</output>
      {if @open == 1}
        <div class="groups">
          {each @groups as group, gi, key: group["id"]}
            <section class="group" data-group="{group['id']}" data-index="{gi}">
              <h2>{group["label"]}</h2>
              {if group["enabled"]}
                <div class="fields">
                  {each group["fields"] as item, fi, key: item["id"]}
                    <div class="field" data-field="{item['id']}" data-index="{fi}">
                      <field-editor field_id="{item['id']}" label="{group['label']} / {item['label']}" initial_value="{item['value']}" on:edit="{record_edit(group['id'], item['id'], gi, fi, $event)}"></field-editor>
                      {if item["help"]}
                        <aside class="help" data-for="{group['id']}:{item['id']}">
                          <button class="pick" onclick="{pick(group['id'], item['id'], gi, fi)}">Help {item["label"]}</button>
                          {if item["invalid"]}<span class="validation">Check {item["label"]}</span>{else}<span class="valid">Ready</span>{end}
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
      {else}
        <p class="closed">Form closed</p>
      {end}
    }
  end
end
