# File contents cross into Ruby as bounded binary strings, one requested chunk
# at a time. The opaque file handle remains owned by its component mount.
class MochiFiles
  def self.open(handle)
    Mochi.file_reader_open(handle)
    handle
  end

  def self.read_next(reader, callback)
    Mochi.host_async("files", "read_next", [reader], callback)
  end

  def self.read(reader, callback)
    Mochi.host_async("files", "read", [reader], callback)
  end

  def self.read_text(reader, callback, encoding = "UTF-8")
    Mochi.host_async("files", "read_text", [reader, encoding], callback)
  end

  def self.cancel(reader)
    close(reader)
  end

  def self.close(reader)
    Mochi.file_reader_close(reader)
    true
  end

  def self.release(handle)
    Mochi.file_release(handle)
  end
end
