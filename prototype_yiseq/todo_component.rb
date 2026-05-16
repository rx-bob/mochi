class TodoList
  def initialize
    @items = []
  end

  def add_item(item)
    @items << item
  end

  def clear
    @items.clear
  end

  def render
    "<ul>" + @items.map { |i| "<li>#{i}</li>" }.join + "</ul>"
  end
end

puts "TodoList loaded"
