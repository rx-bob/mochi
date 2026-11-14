# Bounded UTF-8 JSON, implemented directly in the VM to preserve signed64 integers.
module JSON
  def self.parse(text)
    Mochi.json_parse(text)
  end

  def self.generate(value)
    Mochi.json_generate(value)
  end
end
