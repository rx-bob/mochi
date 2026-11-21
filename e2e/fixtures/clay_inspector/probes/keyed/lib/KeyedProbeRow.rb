class KeyedProbeRow
  @tag_name = "keyed-probe-row"

  prop :slug, String, required: true
  prop :label, String, required: true
  prop :action, String, required: true

  event :command, action: String, name: String, slug: String

  @activated

  def initialize
    @activated = 0
  end

  def activate
    @activated += 1
    emit :command, action: @action, name: @label, slug: @slug
  end

  def unmounted
    count = Mochi.storage_get("unmounts", "0").to_i + 1
    Mochi.storage_set("unmounts", count.to_s)
  end

  def html
    %Q{<button tabindex="0" data-row="yes" onclick="{activate}">{@label} / {@activated}</button>}
  end
end
