# Ref-based geometry arrives through the usual {ok, value, error} callback.
class MochiLayout
  def self.measure(reference, callback)
    Mochi.host_async("layout", "measure", [reference], callback)
  end

  def self.observe(reference, callback)
    Mochi.host_async("layout", "observe", [reference], callback)
  end

  def self.cancel(reference)
    Mochi.host_async("layout", "cancel", [reference], "")
  end
end
