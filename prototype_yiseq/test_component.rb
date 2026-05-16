class TestComponent
  def initialize
    @count = 0
  end

  def increment
    @count += 1
  end

  def render
    "Count is: #{@count}"
  end
end

puts "Component loaded!"
