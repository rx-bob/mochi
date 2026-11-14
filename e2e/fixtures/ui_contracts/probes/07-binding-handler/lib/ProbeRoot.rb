
class ProbeRoot
  @tag_name = "probe-root"

  @query
  @project
  @seen
  def initialize
    @query = ""
    @project = "a"
    @seen = "initial"
  end
  def reset_page
    @seen = "#{@query}:#{@project}"
  end

  def html
    %Q{<input bind:value="@query" oninput="{reset_page}"><select bind:value="@project" onchange="{reset_page}"><option value="a">A</option><option value="b">B</option></select><output class="query">{@query}</output><output class="project">{@project}</output><output class="seen">{@seen}</output>}
  end
end
