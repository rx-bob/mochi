class ProbeRoot
  @tag_name = "probe-root"
  @status
  @parts

  def initialize
    @status = "idle"
    @parts = []
  end

  def save
    MochiDownload.save("résumé.bin", "application/octet-stream", ["\x00\x80", "\xff"])
    @status = "handed off"
  end

  def oversized
    @parts = []
    33.times { @parts << "x" * 8192 }
    parts = @parts
    @parts = []
    MochiDownload.save("too-large.bin", "application/octet-stream", parts)
    @status = "unexpected success"
  end

  def save_string
    MochiDownload.save("résumé.bin", "application/octet-stream", "\x00\x80\xff")
  end

  def html
    %Q{<button class="save" onclick="{save}">Save</button>
      <button class="save-string" onclick="{save_string}">Save String</button>
      <button class="oversized" onclick="{oversized}">Oversized</button><output>{@status}</output>}
  end
end
