# Pointer identity and capture for component-owned event targets.
class MochiPointer
  def self.capture(pointer_id, reference = nil)
    Mochi.pointer_capture(pointer_id, reference)
  end

  def self.release(pointer_id, reference = nil)
    Mochi.pointer_release(pointer_id, reference)
  end
end
