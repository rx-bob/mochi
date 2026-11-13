class ProbeRoot
  @tag_name = "probe-root"
  @records
  @divisor
  @other
  @seen

  computed :rows, depends_on: [:@records, :@divisor]
  computed :label, depends_on: [:rows]
  computed :effect, depends_on: [:@records]

  def initialize
    @records = [{"value" => 12}]
    @divisor = 2
    @other = 0
    @seen = ""
  end

  def rows
    @records.map { |record| {"value" => record["value"] / @divisor} }
  end

  def label
    rows[0]["value"].to_s
  end

  def effect
    ComputedEffects.mutate(@records)
  end

  def try_effect
    @seen = effect
  end

  def unrelated
    @other += 1
    @seen = label
  end

  def replace
    @records = [{"value" => 18}]
    @seen = label
  end

  def change_twice
    @divisor = 3
    @seen = label
    @divisor = 6
    @seen = label
  end

  def fail_computed
    @divisor = 0
  end

  def recover
    @divisor = 3
  end

  def html
    %Q{
      <output class="first">{label}</output>
      <output class="second">{rows[0]["value"]}</output>
      <output class="third">{label}</output>
      <output class="other">{@other}</output>
      <output class="seen">{@seen}</output>
      <button class="unrelated" onclick="{unrelated}">Unrelated</button>
      <button class="replace" onclick="{replace}">Replace root</button>
      <button class="twice" onclick="{change_twice}">Change twice</button>
      <button class="fail" onclick="{fail_computed}">Fail</button>
      <button class="recover" onclick="{recover}">Recover</button>
      <button class="effect" onclick="{try_effect}">Attempt effect</button>
    }
  end
end
