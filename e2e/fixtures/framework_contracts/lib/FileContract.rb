class FileContract
  @tag_name = "file-contract"
  @input_files
  @drop_files
  @reader
  @byte_count
  @checksum
  @stream_state

  def initialize
    @input_files = []
    @drop_files = []
    @byte_count = 0
    @checksum = 0
    @stream_state = "idle"
  end

  def receive_input(event)
    @input_files = event["files"]
    if @input_files.length > 0
      @reader = MochiFiles.open(@input_files[@input_files.length - 1]["handle"])
      @byte_count = 0
      @checksum = 0
      @stream_state = "reading"
      MochiFiles.read_next(@reader, :on_file_chunk)
    end
  end

  # Ordinary Ruby pulls the next fixed-size chunk only after it has consumed
  # the current binary string. No base64 or browser objects reach this code.
  def on_file_chunk(result)
    if !result["ok"]
      @stream_state = "error"
      MochiFiles.close(@reader)
      return
    end
    chunk_result = result["value"]
    if chunk_result["state"] == "chunk"
      bytes = chunk_result["bytes"]
      index = 0
      while index < bytes.bytesize
        @checksum = (@checksum * 31 + bytes.getbyte(index)) % 2147483647
        @byte_count += 1
        index += 1
      end
      MochiFiles.read_next(@reader, :on_file_chunk)
    else
      @stream_state = chunk_result["state"]
      MochiFiles.close(@reader)
    end
  end

  def receive_drop(event)
    @drop_files = event["files"]
  end

  def describe(files)
    files.map do |file|
      "#{file["name"]}:#{file["size"]}:#{file["type"]}:#{file["last_modified"]}:#{file["handle"]}"
    end.join("|")
  end

  def html
    %Q{
      <input class="file-input" type="file" multiple onchange="{receive_input($event)}">
      <section class="file-drop" ondrop="{receive_drop($event)}">Drop files here</section>
      <output class="input-files">{describe(@input_files)}</output>
      <output class="drop-files">{describe(@drop_files)}</output>
      <output class="stream-result">{@stream_state}:{@byte_count}:{@checksum}</output>
    }
  end
end
