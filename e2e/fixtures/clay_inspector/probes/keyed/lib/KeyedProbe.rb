class KeyedProbe
  @tag_name = "keyed-probe"

  @rows
  @original
  @separate
  @last
  @unmounts

  def initialize
    @original = [
      {"key" => 1, "slug" => "a", "name" => "Alder", "action" => "reverse"},
      {"key" => "1", "slug" => "b", "name" => "Birch", "action" => "remove"},
      {"key" => false, "slug" => "c", "name" => "Cedar", "action" => "reverse"}
    ]
    @rows = @original
    @separate = [{"key" => 1, "slug" => "other", "name" => "Other", "action" => "reverse"}]
    @last = ""
    @unmounts = Mochi.storage_get("unmounts", "0")
    Mochi.storage_subscribe("unmounts", :observe)
  end

  def observe(event)
    @unmounts = event["value"] || "0"
  end

  def duplicate
    invalid = {"key" => false, "slug" => "c", "name" => "Invalid Cedar", "action" => "reverse"}
    @rows = [invalid, @original[0], @original[0]]
  end

  def replace
    revised = {"key" => 1, "slug" => "a", "name" => "Updated Alder", "action" => "reverse"}
    @rows = [@original[2], @original[1], revised]
  end

  def apply(event)
    @last = event["name"]
    if event["action"] == "remove"
      @rows = @rows.select { |row| row["slug"] != event["slug"] }
    else
      @rows = @rows.reverse
    end
  end

  def mark_other
    @last = "Other list"
  end

  def html
    %Q{
      <div>
        <button data-duplicate="yes" onclick="{duplicate}">Duplicate keys</button>
        <button data-replace="yes" onclick="{replace}">Replace data</button>
        {each @rows as row, key: row["key"]}
          <keyed-probe-row data-primary="{row["slug"]}" slug="{row["slug"]}" label="{row["name"]}" action="{row["action"]}" on:command="{apply($event)}"></keyed-probe-row>
        {end}
        {each @separate as row, key: row["key"]}
          <keyed-probe-row data-secondary="{row["slug"]}" slug="{row["slug"]}" label="{row["name"]}" action="{row["action"]}" on:command="{mark_other}"></keyed-probe-row>
        {end}
        <span data-last="yes">{@last}</span>
        <span data-unmounts="yes">Unmounts {@unmounts}</span>
      </div>
    }
  end
end
