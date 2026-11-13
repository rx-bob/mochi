class NetworkPanel
  @tag_name = "network-panel"
  @items

  def initialize
    @items = "waiting"
  end

  def html
    %Q{<section>{@items}</section>}
  end

  def mounted
    Mochi.fetch("/api/items", :receive_items)
  end

  def receive_items(result)
    @items = result
  end
end
