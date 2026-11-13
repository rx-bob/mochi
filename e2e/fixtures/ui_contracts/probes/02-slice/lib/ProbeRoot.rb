
class ProbeRoot
  @tag_name = "probe-root"

  @value
  @items
  def initialize
    @value = [1, 2, 3, 4].slice(1, 2).to_s
    @items = [1, 2, 3, 4].slice(1, 2)
  end

  def html
    %Q{<output class="original-text">{@value}</output><output class="items">{@items.length}:{@items.join(',')}</output>}
  end
end
