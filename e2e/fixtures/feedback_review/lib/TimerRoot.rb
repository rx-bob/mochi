class TimerRoot
  @tag_name = "timer-root"

  def initialize
    @ticks = 0
    @once_handle = nil
    @poll_handle = nil
  end

  def start_once
    @once_handle = Mochi.after(0, :once_tick)
  end

  def once_tick
    @ticks = @ticks + 1
    @once_handle = nil
  end

  def start_polling
    return if @poll_handle
    @poll_handle = Mochi.every(10, "poll_tick")
  end

  def poll_tick
    @ticks = @ticks + 1
  end

  def stop_polling
    return unless @poll_handle
    Mochi.cancel_timer(@poll_handle)
    Mochi.cancel_timer(@poll_handle)
    @poll_handle = nil
  end

  def invalid_delay
    Mochi.after(-1, :once_tick)
  end

  def invalid_delay_type
    Mochi.after(1.5, :once_tick)
  end

  def excessive_delay
    Mochi.after(2147483648, :once_tick)
  end

  def invalid_callback
    Mochi.after(0, :missing_tick)
  end

  def invalid_callback_type
    Mochi.every(0, 7)
  end

  def required_argument(value)
    @ticks = value
  end

  def invalid_callback_arity
    Mochi.after(0, :required_argument)
  end

  def start_failing_once
    Mochi.after(50, :fail_once)
  end

  def fail_once
    1 / 0
  end

  def invalid_handle
    Mochi.cancel_timer("not a handle")
  end

  def unmounted
    stop_polling
  end

  def html
    %Q{
      <button class="once" onclick="{start_once}">Once</button>
      <button class="start" onclick="{start_polling}">Start</button>
      <button class="stop" onclick="{stop_polling}">Stop</button>
      <button class="bad-delay" onclick="{invalid_delay}">Bad delay</button>
      <button class="bad-delay-type" onclick="{invalid_delay_type}">Bad delay type</button>
      <button class="long-delay" onclick="{excessive_delay}">Long delay</button>
      <button class="bad-callback" onclick="{invalid_callback}">Bad callback</button>
      <button class="bad-callback-type" onclick="{invalid_callback_type}">Bad callback type</button>
      <button class="bad-callback-arity" onclick="{invalid_callback_arity}">Bad callback arity</button>
      <button class="bad-handle" onclick="{invalid_handle}">Bad handle</button>
      <button class="fail-once" onclick="{start_failing_once}">Fail once</button>
      <output class="ticks">{@ticks}</output>
    }
  end
end

class TimerFailure
  @tag_name = "timer-failure"

  def initialize
    @timer = Mochi.after(0, :tick)
    1 / 0
  end

  def tick
  end

  def html
    %Q{<output>unreachable</output>}
  end
end
