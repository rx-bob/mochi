class DummyComponent1
  def initialize
    @state_1 = 1
  end

  def mutate_1
    @state_1 += 1
  end

  def render
    "State 1 is: #{@state_1}"
  end
end
puts "Dummy 1 loaded"
