class TodoList
  def initialize
    @items = []
    @next_id = 1
  end

  def add_item
    @items << { id: @next_id, text: "Task #{@next_id}", done: false }
    @next_id += 1
  end

  def toggle_last
    return if @items.empty?
    last = @items.last
    last[:done] = !last[:done]
  end

  def remove_last
    @items.pop unless @items.empty?
  end

  def html
    items_html = @items.map { |item|
      cls = item[:done] ? 'done' : ''
      "<li class='#{cls}'>#{item[:text]}#{item[:done] ? ' ✓' : ''}</li>"
    }.join

    "<div class='todo'>" \
      "<h2>Todo List (#{@items.length} items)</h2>" \
      "<ul>#{items_html}</ul>" \
      "<div class='buttons'>" \
        "<button data-action='add_item'>Add</button>" \
        "<button data-action='toggle_last'>Toggle Last</button>" \
        "<button data-action='remove_last'>Remove Last</button>" \
      "</div>" \
    "</div>"
  end
end
