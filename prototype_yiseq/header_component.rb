class HeaderComponent
  def initialize
    @title = "Welcome to Mochi"
  end

  def change_title(new_title)
    @title = new_title
  end

  def render
    "<h1>#{@title}</h1>"
  end
end

puts "Header loaded"
