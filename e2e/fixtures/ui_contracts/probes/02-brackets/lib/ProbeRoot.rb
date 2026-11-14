
class ProbeRoot
  @tag_name = "probe-root"

  @value
  @items
  def initialize
    arr = [1, 2, 3, 4]
    @value = arr[1, 2].to_s
    @items = arr[1, 2]
  end

  def html
    %Q{<output class="original-text">{@value}</output><output class="items">{@items.length}:{@items.join(',')}</output>}
  end
end
