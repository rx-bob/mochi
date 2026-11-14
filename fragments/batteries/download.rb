# A single bounded download. Parts may be binary Strings; no JSON wire encoding.
class MochiDownload
  def self.save(filename, content_type, content)
    Mochi.download(filename, content_type, content)
  end
end
