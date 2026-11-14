class ReviewRoot
  @tag_name = "review-root"
  def initialize
    @show = true
    @rows = [{"id" => "a", "label" => "Alpha", "meta" => {"value" => "A"}}, {"id" => "b", "label" => "Beta", "meta" => {"value" => "B"}}]
    @groups = [{"id" => "group", "rows" => @rows}]
    @result = "idle"
    @ticks = 0
    @fail_helper = false
  end
  def toggle
    @show = !@show
  end
  def replace
    @rows = [{"id" => "b", "label" => "Beta2", "meta" => {"value" => "B2"}}, {"id" => "a", "label" => "Alpha2", "meta" => {"value" => "A2"}}]
    @groups = [{"id" => "group", "rows" => @rows}]
  end
  def receive(event)
    @result = event["value"]
  end
  def drag(event)
    @result = event["current_target_dataset"]["id"]
    MochiDrag.set_text(@result)
  end
  def body
    %Q{<b class="raw-body">Review {literal} #{1 + 2}</b>}
  end
  def icon
    %Q{<svg class="icon" width="12" height="12"><circle r="3" cx="6" cy="6"></circle></svg>}
  end
  def start
    @timer = Mochi.every(20, "tick")
  end
  def tick
    @ticks = @ticks + 1
  end
  def stop
    Mochi.cancel_timer(@timer)
  end
  def save
    Mochi.storage_set("mochi-feedback-review", "saved")
  end
  def read
    @result = Mochi.storage_get("mochi-feedback-review", "missing")
  end
  def fail_helper
    @fail_helper = true
  end
  def recover_helper
    @fail_helper = false
  end
  def diagnostic
    @rows.first.fetch_missing_value if @fail_helper
    "ready"
  end
  def html
    %Q{
      <main>
        <button class="toggle" onclick="{toggle}">Toggle</button><button class="replace" onclick="{replace}">Replace</button>
        <button class="start" onclick="{start}">Start</button><button class="stop" onclick="{stop}">Stop</button>
        <button class="save" onclick="{save}">Save</button><button class="read" onclick="{read}">Read</button>
        <button class="fail-helper" onclick="{fail_helper}">Fail helper</button><button class="recover-helper" onclick="{recover_helper}">Recover helper</button>
        <output>{@result}</output><span class="ticks">{@ticks}</span><span class="diagnostic">{diagnostic}</span>
        <div class="mixed">Before {Mochi.raw(icon)} after</div>
        {if @show}
          <section class="modal">{Mochi.raw(body)}
            {each @groups as group, key: group["id"]}
            {each group["rows"] as row, key: row["id"]}
              <div data-row="{row['id']}">
                <review-child label="{row['label']}" meta="{row['meta']}" on:action="{receive($event)}" on:change="{receive($event)}"></review-child>
                <button class="drag" draggable="true" data-id="{row['id']}" ondragstart="{drag($event)}"><span>Drag</span></button>
              </div>
            {end}
            {end}
          </section>
        {end}
      </main>
    }
  end
end
