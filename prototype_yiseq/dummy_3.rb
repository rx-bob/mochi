class DummyComponent3
  def initialize
    @state_3 = 3
  end

  def mutate_3
    @state_3 += 1
  end

  def render
    "State 3 is: #{@state_3}"
  end
end
puts "Dummy 3 loaded"
