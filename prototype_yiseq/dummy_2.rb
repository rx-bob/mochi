class DummyComponent2
  def initialize
    @state_2 = 2
  end

  def mutate_2
    @state_2 += 1
  end

  def render
    "State 2 is: #{@state_2}"
  end
end
puts "Dummy 2 loaded"
