class DummyComponent5
  def initialize
    @state_5 = 5
  end

  def mutate_5
    @state_5 += 1
  end

  def render
    "State 5 is: #{@state_5}"
  end
end
puts "Dummy 5 loaded"
