class Counter
  def initialize
    @count = 0
    @label = "Click me"
  end

  def increment
    @count += 1
  end

  def decrement
    @count -= 1
  end

  def reset
    @count = 0
  end

  def html
    "<div class='counter'>" \
      "<h2>#{@label}</h2>" \
      "<span class='count'>#{@count}</span>" \
      "<div class='buttons'>" \
        "<button data-action='decrement'>-</button>" \
        "<button data-action='increment'>+</button>" \
        "<button data-action='reset'>Reset</button>" \
      "</div>" \
    "</div>"
  end
end
