module StationNumbers
  def self.id(text)
    text.to_i
  end

  def self.label(id)
    id < 10 ? "0#{id}" : id.to_s
  end
end
