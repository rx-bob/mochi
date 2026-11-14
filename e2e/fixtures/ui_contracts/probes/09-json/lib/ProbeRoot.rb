require 'json'
class ProbeRoot
  @tag_name = "probe-root"

  @value
  computed :computed_json, depends_on: [:@value]

  def computed_json
    JSON.generate(JSON.parse(@value))
  end

  def initialize
    @value = JSON.generate(JSON.parse('{"id":9007199254740993}'))
  end

  def valid
    @value = JSON.generate(JSON.parse('{"id":9007199254740993}'))
  end

  def malformed
    @value = JSON.parse('{"unfinished":')
  end

  def cycle
    value = []
    value << value
    @value = JSON.generate(value)
  end

  def unsupported
    @value = JSON.generate(self)
  end

  def nonfinite
    @value = JSON.generate(1.0 / 0.0)
  end

  def too_deep
    @value = JSON.parse('[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]')
  end

  def too_large
    @value = JSON.generate("x" * 48000)
  end

  def html
    %Q{
      <output>{@value}</output><span class="computed">{computed_json}</span>
      <button class="valid" onclick="{valid}">Valid</button>
      <button class="malformed" onclick="{malformed}">Malformed</button>
      <button class="cycle" onclick="{cycle}">Cycle</button>
      <button class="unsupported" onclick="{unsupported}">Unsupported</button>
      <button class="nonfinite" onclick="{nonfinite}">Nonfinite</button>
      <button class="too-deep" onclick="{too_deep}">Too deep</button>
      <button class="too-large" onclick="{too_large}">Too large</button>
    }
  end
end
