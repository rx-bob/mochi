50.times do |i|
  content = <<-RUBY
class DummyComponent#{i}
  def initialize
    @state_#{i} = #{i}
  end

  def mutate_#{i}
    @state_#{i} += 1
  end

  def render
    "State #{i} is: \#{@state_#{i}}"
  end
end
puts "Dummy #{i} loaded"
  RUBY
  File.write("dummy_#{i}.rb", content)
end
