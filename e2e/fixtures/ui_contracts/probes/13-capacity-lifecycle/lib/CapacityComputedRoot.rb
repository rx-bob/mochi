class CapacityComputedRoot
  @tag_name = "capacity-computed-root"
  prop :fail_mount, Boolean, default: false
  @mode
  @status
  @retained

  computed :projection, depends_on: [:@mode, :one, :two, :three, :four]
  computed :one, depends_on: []
  computed :two, depends_on: []
  computed :three, depends_on: []
  computed :four, depends_on: []

  def initialize
    @mode = @fail_mount ? "objects" : "ready"
    @status = "ready"
    @retained = []
  end

  def one
    1
  end

  def two
    2
  end

  def three
    3
  end

  def four
    4
  end

  def projection
    if @mode == "objects"
      rows = []
      150.times { rows << "item" }
      rows.length
    elsif @mode == "bytes"
      text = "x"
      14.times { text = text + text }
      text.length
    elsif @mode == "cache"
      one + two + three + four
    else
      1
    end
  end

  def fail_projection(event)
    @status = "pending"
    @mode = event["current_target_dataset"]["mode"]
    Mochi.storage_set("capacity-projection", "must-not-publish")
  end

  def fill_state
    @status = "pending"
    Mochi.storage_set("capacity-projection", "must-not-publish")
    # Deliberately commits each record to exercise nontransactional failure.
    # A local replacement would exhaust scratch first, obscuring state pressure.
    700.times do |index|
      text = "x"
      10.times { text = text + text }
      @retained << "#{index}:#{text}"
    end
  end

  def recover
    previous = @status
    retained_count = @retained.length
    @retained = []
    @mode = "ready"
    @status = "#{previous}:#{retained_count}:recovered"
  end

  def html
    %Q{
      <output class="status">{@status}</output><output class="projection">{projection}</output>
      <button class="objects" data-mode="objects" onclick="{fail_projection($event)}">Objects</button>
      <button class="bytes" data-mode="bytes" onclick="{fail_projection($event)}">Bytes</button>
      <button class="cache" data-mode="cache" onclick="{fail_projection($event)}">Cache</button>
      <button class="state" onclick="{fill_state}">State</button>
      <button class="recover" onclick="{recover}">Recover</button>
    }
  end
end
