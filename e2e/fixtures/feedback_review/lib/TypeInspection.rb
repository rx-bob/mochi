class TypeInspectionBase
  Integer = "lexical"

  def shadowed_constant
    Integer
  end
end

class TypeInspection < TypeInspectionBase
  @tag_name = "type-inspection"
  prop :items, Array, required: true
  prop :meta, Hash, required: true

  def initialize
    @init_report = report
    @event_report = "pending"
  end

  def helper_array
    []
  end

  def helper_hash
    {}
  end

  def report
    [
      [].is_a?(Array),
      ({}).is_a?(Hash),
      1.is_a?(Integer),
      1099511627776.is_a?(Integer),
      1.0.is_a?(Float),
      "x".is_a?(String),
      :x.is_a?(Symbol),
      true.is_a?(TrueClass),
      false.is_a?(FalseClass),
      nil.is_a?(NilClass),
      @items.is_a?(Array),
      @meta.is_a?(Hash),
      helper_array.is_a?(Array),
      helper_hash.is_a?(Hash),
      self.is_a?(TypeInspectionBase),
      self.is_a?(Object),
      shadowed_constant == "lexical",
      RubySurfaceHelpers.integer_type?(1099511627776),
      ![].is_a?(Hash),
      !({}).is_a?(Array),
      !1.0.is_a?(Integer),
      !1099511627776.is_a?(Float),
      !true.is_a?(FalseClass),
      !false.is_a?(TrueClass),
      !"x".is_a?(Symbol),
      !self.is_a?(String),
    ].join("|")
  end

  def check
    @event_report = report
  end

  def bad_arity
    1.is_a?(Integer, Float)
  end

  def bad_type
    1.is_a?(1)
  end

  def html
    %Q{
      <main>
        <output class="init">{@init_report}</output>
        <output class="binding">{report}</output>
        <output class="event">{@event_report}</output>
        {each @items as value}
          <output class="each-type">{RubySurfaceHelpers.integer_type?(value)}</output>
        {end}
        <button class="check" onclick="{check}">Check</button>
        <button class="bad-arity" onclick="{bad_arity}">Bad arity</button>
        <button class="bad-type" onclick="{bad_type}">Bad type</button>
      </main>
    }
  end
end
