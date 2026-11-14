module RecordData
  BASE = 1794571200000

  def self.base_ms
    BASE
  end

  def self.build
    total = 0
    kept = []
    [1, 2, 3].each do |item|
      next if item == 2
      total += item
      kept << item
    end
    mapped = [1, 2, 3].map do |item|
      next BASE if item == 2
      item + 10
    end
    nested = 0
    [1, 2].each do |outer|
      [1, 2, 3].each do |inner|
        next if inner == 2
        nested += outer * inner
      end
    end
    "#{kept.join(',')}:#{mapped.join(',')}:#{total}:#{nested}:after"
  end
end
