# typed: true
# Counter component — Sorbet-typed Ruby that compiles to mruby/WASM
# All type annotations are stripped at build time; only the mruby bytecode ships.

class Counter
  extend T::Sig

  sig { void }
  def initialize
    @count = T.let(0, Integer)
    @label = T.let("Click me", String)
  end

  sig { void }
  def increment
    @count += 1
  end

  sig { void }
  def decrement
    @count -= 1
  end

  sig { void }
  def reset
    @count = 0
  end

  sig { returns(String) }
  def html
    "<div class='counter'>" \
      "<h2>#{@label}</h2>" \
      "<span class='count'>#{@count}</span>" \
      "<div class='buttons'>" \
        "<button data-action='decrement'>-</button>" \
        "<button data-action='increment'>+</button>" \
        "<button data-action='reset'>Reset</button>" \
      "</div>" \
    "</div>"
  end
end
