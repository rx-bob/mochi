class KeyedStateChild
  @tag_name = "keyed-state-child"
  prop :row_id, String, required: true
  prop :label, String, required: true
  @local_count

  def initialize
    @local_count = 0
    @mount_count = 0
  end

  def increment
    @local_count += 1
  end

  def mounted
    @mount_count += 1
    Mochi.route_subscribe
    Mochi.storage_subscribe("keyed-state:" + @row_id, "on_storage")
  end

  def on_route(payload)
    @last_path = payload["path"]
  end

  def on_storage(payload)
    @last_storage_value = payload["value"]
  end

  def html
    %Q{
      <section class="state-child" data-row-id="{@row_id}">
        <span class="child-label">{@label}</span>
        <span class="local-count">{@local_count}</span>
        <span class="mount-count">{@mount_count}</span>
        <input class="draft" aria-label="draft {@row_id}">
        <button class="increment" onclick="{increment}">Increment</button>
      </section>
    }
  end
end

class KeyedStateRoot
  @tag_name = "keyed-state-root"
  @rows

  def initialize
    @rows = [
      {"id" => "a", "label" => "Alpha"},
      {"id" => "b", "label" => "Beta"}
    ]
  end

  def prepend
    @rows = [{"id" => "c", "label" => "Charlie"}, @rows[0], @rows[1]]
  end

  def reverse
    @rows = [@rows[2], @rows[1], @rows[0]]
  end

  def remove_a
    if @rows[0]["id"] == "a"
      @rows = [@rows[1], @rows[2]]
    elsif @rows[1]["id"] == "a"
      @rows = [@rows[0], @rows[2]]
    else
      @rows = [@rows[0], @rows[1]]
    end
  end

  def reinsert_a
    @rows = [@rows[0], @rows[1], {"id" => "a", "label" => "Alpha fresh"}]
  end

  def html
    %Q{
      <button class="prepend" onclick="{prepend}">Prepend</button>
      <button class="reverse" onclick="{reverse}">Reverse</button>
      <button class="remove-a" onclick="{remove_a}">Remove A</button>
      <button class="reinsert-a" onclick="{reinsert_a}">Reinsert A</button>
      <ul class="rows">
        {each @rows as row, key: row["id"]}
          <li class="row" data-row="{row["id"]}">
            <keyed-state-child row_id="{row["id"]}" label="{row["label"]}"></keyed-state-child>
          </li>
        {end}
      </ul>
    }
  end
end
