# Synchronous, mount-owned browser drag transfer. Call these methods from the
# matching native dragstart/dragover handler; Ruby never receives DataTransfer.
class MochiDrag
  def self.set_data(value)
    Mochi.drag_set_data(value)
  end

  def self.set_text(text)
    Mochi.drag_set_text(text)
  end

  def self.accept(type, effect = "copy")
    Mochi.drag_accept(type, effect)
  end
end
