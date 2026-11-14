class ProbeRoot
  @tag_name = "probe-root"
  @query
  @calls

  def initialize
    @query = "old"
    @calls = 0
  end

  def observe
    @calls += 1
    Mochi.storage_set("bound-handler", @query)
  end

  def html
    %Q{<input bind:value="{@query}" oninput="{observe}"><output class="query">{@query}</output><output class="calls">{@calls}</output>}
  end
end
