class DummyComponent4
  def initialize
    @state_4 = 4
  end

  def mutate_4
    @state_4 += 1
  end

  def render
    "State 4 is: #{@state_4}"
  end
end
puts "Dummy 4 loaded"
