module ComputedEffects
  def self.mutate(records)
    records[0]["value"] = 99
  end
end
