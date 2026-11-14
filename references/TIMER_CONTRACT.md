# Mount-owned timers

Mochi provides one scheduler through the component's existing host connection:

```ruby
handle = Mochi.after(milliseconds, :refresh) # one callback
handle = Mochi.every(milliseconds, "refresh") # repeated callback
Mochi.cancel_timer(handle)
```

`after(delay_ms, callback)` and `every(delay_ms, callback)` take exactly two
positional arguments. The delay must be an Integer from `0` through
`2_147_483_647`, inclusive, in milliseconds. Zero is valid. It is asynchronous;
the browser may clamp a zero-delay timeout or interval to its minimum timer
resolution. Use a positive interval for polling rather than depending on
zero-delay cadence.

The callback is the name of a method on the component instance, supplied as a
String or Symbol. It must resolve when scheduled and be callable with no
required positional arguments. Blocks, Procs, and JavaScript callbacks are not
accepted. A missing method, an invalid callback value, a delay outside the
range, or an invalid handle fails at the Ruby call site through the regular
`mochi:error` path. Wrong argument counts report `wrong number of arguments`;
wrong value types report `type mismatch` or the timer-specific error. Invalid
calls do not create a live timer. A later valid event can still run.

Both scheduling methods return a positive Integer handle. `after` delivers its
callback once; `every` continues until canceled or its mount is disposed.
`cancel_timer(handle)` takes exactly one argument and returns `true`. Passing
`nil`, canceling an already-canceled handle, or canceling an unknown positive
Integer handle is a harmless no-op. Other value types and nonpositive integers
are errors. A handle can cancel only a timer owned by the component instance
that received it.

Timer registration works from `initialize`, `mounted`, and ordinary component
methods such as event handlers. It is a host side effect, so computed bindings
cannot schedule timers. Callbacks run as zero-argument instance methods through
the normal VM event path. Callback errors are reported with phase `timer`; a
repeating timer remains active after a callback error and can be canceled or
will be released with its mount.

Timers belong to one component mount. Mochi cancels them on settled removal,
including removal after a failed mount; no callback from an old mount can reach
a replacement instance. Moving a still-connected component preserves its
mount and timers. Reconnecting after disposal creates a fresh instance. The
browser owns the actual clock: background tabs may throttle timers, and Mochi
does not promise exact cadence or calendar scheduling.

## Ruby polling example

This checked-in example starts polling explicitly, permits an explicit stop,
and stops the timer during normal unmount cleanup:

```ruby
class PollingPanel
  @tag_name = "polling-panel"

  def initialize
    @poll_handle = nil
    @ticks = 0
  end

  def start_polling
    return if @poll_handle
    @poll_handle = Mochi.every(1000, :refresh)
  end

  def refresh
    @ticks = @ticks + 1
  end

  def stop_polling
    return unless @poll_handle
    Mochi.cancel_timer(@poll_handle)
    @poll_handle = nil
  end

  def unmounted
    stop_polling
  end
end
```

The executable version used by the three-engine regression is
[`TimerRoot.rb`](../e2e/fixtures/feedback_review/lib/TimerRoot.rb). It exercises
one-shot delivery, repeated delivery, explicit cancellation, and unmount
cleanup with a controlled browser clock.
