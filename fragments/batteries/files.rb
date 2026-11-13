# File metadata is safe to pass through Ruby. Contents remain behind the
# opaque handle until a later bounded-read API is used.
class MochiFiles
  def self.release(handle)
    Mochi.file_release(handle)
  end
end
