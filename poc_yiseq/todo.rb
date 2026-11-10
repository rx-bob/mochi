# typed: true
# TodoList component — Sorbet-typed Ruby that compiles to mruby/WASM

class TodoList
  extend T::Sig

  Item = T.type_alias { { id: Integer, text: String, done: T::Boolean } }

  sig { void }
  def initialize
    @items = T.let([], T::Array[Item])
    @next_id = T.let(1, Integer)
  end

  sig { void }
  def add_item
    item = { id: @next_id, text: "Task #{@next_id}", done: false }
    @items << item
    @next_id += 1
  end

  sig { void }
  def toggle_last
    return if @items.empty?
    last = T.must(@items.last)
    last[:done] = !last[:done]
  end

  sig { void }
  def remove_last
    @items.pop unless @items.empty?
  end

  sig { returns(String) }
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
