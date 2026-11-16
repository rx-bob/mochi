class GroupedPropsChild
  @tag_name = "grouped-props-child"
  prop :label, String, required: true
  prop :count, Integer, required: true
  prop :active, Boolean, default: false
  prop :metadata, Hash, required: true
  prop :values, Array, default: []
  prop :defaults, Array, default: []
  prop :settings, Hash, default: {}

  def initialize
    @initial_note = @metadata["note"]
  end

  # mochi-lint: disable-next components/prop-write -- fixture proves child-local mutations cannot change a parent's declared prop snapshot
  def change
    @metadata["note"] = "child-only"
    @values[0] = "child-only"
    @defaults << "child-only"
    @settings["child-only"] = true
  end

  def current_note
    @metadata["note"]
  end

  def first_value
    @values[0]
  end

  def default_count
    @defaults.length
  end

  def setting_count
    @settings.length
  end

  def summary
    @label + ":" + @count.to_s
  end

  def html
    %Q{
      <section class="typed-child" data-label="{@label}" data-count="{@count}" data-active="{@active}">
        <span class="initial-note">{@initial_note}</span>
        <span class="note">{current_note}</span>
        <span class="first-value">{first_value}</span>
        <span class="summary">{summary}</span>
        <span class="default-count">{default_count}</span>
        <span class="setting-count">{setting_count}</span>
        <button class="mutate" onclick="{change}">Mutate</button>
      </section>
    }
  end
end

class PropsInspector
  @tag_name = "props-inspector"
  prop :metadata, Hash, required: true

  def note
    @metadata["note"]
  end

  def empty_value
    @metadata["empty"]
  end

  def count
    @metadata["count"]
  end

  def active
    @metadata["active"]
  end

  def html
    %Q{<aside class="inspector" data-note="{note}" data-empty="{empty_value}" data-count="{count}" data-active="{active}">{note}</aside>}
  end
end

class GroupedPropsRoot
  @tag_name = "grouped-props-root"
  @groups
  @inspector_open
  @inspection
  @static_metadata
  @static_values

  def initialize
    @groups = [
      {"id" => "north", "items" => [
        {"id" => "a", "label" => "Alpha", "count" => 0, "active" => false, "metadata" => {"note" => "north-a", "empty" => "", "count" => 0, "active" => false}, "values" => ["a-value"]},
        {"id" => "b", "label" => "Beta", "count" => 2, "active" => true, "metadata" => {"note" => "north-b", "empty" => "", "count" => 2, "active" => true}, "values" => ["b-value"]}
      ]},
      {"id" => "south", "items" => [
        {"id" => "c", "label" => "Gamma", "count" => 3, "active" => false, "metadata" => {"note" => "south-c", "empty" => "", "count" => 3, "active" => false}, "values" => ["c-value"]}
      ]}
    ]
    @inspector_open = false
    @inspection = {"note" => "inspection", "empty" => "", "count" => 0, "active" => false}
    @static_metadata = {"note" => "static", "empty" => "", "count" => 0, "active" => false}
    @static_values = ["static-value"]
  end

  def open_inspector
    @inspector_open = true
  end

  def update_pair
    @groups[0]["items"][0]["label"] = "Alpine"
    @groups[0]["items"][0]["count"] = 4
    @groups[0]["items"][0]["metadata"]["note"] = "updated"
    @inspection["note"] = "updated-inspection"
  end

  def clear_groups
    @groups = []
  end

  def close_inspector
    @inspector_open = false
  end

  def parent_note
    return "empty" if @groups.empty?
    @groups[0]["items"][0]["metadata"]["note"]
  end

  def html
    %Q{
      <button class="open-inspector" onclick="{open_inspector}">Inspect</button>
      <button class="close-inspector" onclick="{close_inspector}">Close inspector</button>
      <button class="update-pair" onclick="{update_pair}">Update</button>
      <button class="clear-groups" onclick="{clear_groups}">Clear groups</button>
      <span class="parent-note">{parent_note}</span>
      <grouped-props-child data-item="static" label="Static" count="0" active="false" metadata="{@static_metadata}" values="{@static_values}"></grouped-props-child>
      {each @groups as group, key: group["id"]}
        <div class="group" data-group="{group["id"]}">
          {each group["items"] as item, key: item["id"]}
            <grouped-props-child data-item="{item["id"]}" label="{item["label"]}" count="{item["count"]}" active="{item["active"]}" metadata="{item["metadata"]}" values="{item["values"]}"></grouped-props-child>
          {end}
        </div>
      {end}
      {if @inspector_open}
        <grouped-props-child data-item="conditional" label="Conditional" count="0" active="false" metadata="{@inspection}" values="{@static_values}"></grouped-props-child>
        <props-inspector metadata="{@inspection}"></props-inspector>
      {end}
    }
  end
end
