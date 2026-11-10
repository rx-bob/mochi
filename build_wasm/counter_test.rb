# counter_test.rb — minimal mruby-compatible component
# Compile with: mrbc -o counter_test.mrb counter_test.rb

class CounterTest
  def initialize
    @count = 0
  end

  def html
    "<div class='mochi' data-tag='counter-test'><h1>Count: #{@count}</h1><button data-on-click='increment'>+1</button></div>"
  end

  def css
    ""
  end

  def increment
    @count += 1
  end
end
