class FileContract
  @tag_name = "file-contract"
  @input_files
  @drop_files
  @reader
  @byte_count
  @checksum
  @stream_state
  @whole_state
  @active_handle

  def initialize
    @input_files = []
    @drop_files = []
    @byte_count = 0
    @checksum = 0
    @stream_state = "idle"
    @whole_state = "idle"
  end

  def receive_input(event)
    @input_files = event["files"]
    consume_files(@input_files)
  end

  def receive_drop(event)
    @drop_files = event["files"]
    consume_files(@drop_files)
  end

  def consume_files(files)
    return if files.length == 0
    file = files[(files.length - 1)]
    files.each do |candidate|
      MochiFiles.release(candidate["handle"]) if candidate["handle"] != file["handle"]
    end
    @active_handle = file["handle"]
    @reader = MochiFiles.open(@active_handle)
    @byte_count = 0
    @checksum = 0
    @whole_state = "reading"
    if file["type"] == "text/plain"
      MochiFiles.read_text(@reader, :on_whole_text)
    else
      MochiFiles.read(@reader, :on_whole_bytes)
    end
  end

  def on_whole_bytes(result)
    if !result["ok"]
      if result["error"] == "file exceeds configured whole-file read limit"
        start_stream
      else
        @whole_state = "error:#{result["error"]}"
        MochiFiles.release(@active_handle)
      end
      return
    end
    bytes = result["value"]
    index = 0
    checksum = 0
    while index < bytes.bytesize
      checksum = (checksum * 31 + bytes.getbyte(index)) % 2147483647
      index += 1
    end
    @whole_state = "bytes:#{bytes.bytesize}:#{checksum}"
    MochiFiles.release(@active_handle)
  end

  def on_whole_text(result)
    if !result["ok"]
      if result["error"] == "file exceeds configured whole-file read limit"
        start_stream
      else
        @whole_state = "error:#{result["error"]}"
        MochiFiles.release(@active_handle)
      end
      return
    end
    text = result["value"]
    @whole_state = "text:#{text.bytesize}:#{text[8191, 3]}"
    MochiFiles.release(@active_handle)
  end

  def start_stream
    @reader = MochiFiles.open(@active_handle)
    @byte_count = 0
    @checksum = 0
    @stream_state = "reading"
    MochiFiles.read_next(@reader, :on_file_chunk)
  end

  # Ordinary Ruby pulls the next fixed-size chunk only after it has consumed
  # the current binary string. No base64 or browser objects reach this code.
  def on_file_chunk(result)
    if !result["ok"]
      @stream_state = "error"
      MochiFiles.close(@reader)
      MochiFiles.release(@active_handle)
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
      MochiFiles.release(@active_handle)
    end
  end

  def cancel_stream
    return if @whole_state != "reading" && @stream_state != "reading"
    MochiFiles.cancel(@reader)
    MochiFiles.release(@active_handle)
    if @stream_state == "reading"
      @stream_state = "cancelled"
    else
      @whole_state = "cancelled"
    end
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
      <button class="cancel-stream" onclick="{cancel_stream}">Cancel read</button>
      <output class="input-files">{describe(@input_files)}</output>
      <output class="drop-files">{describe(@drop_files)}</output>
      <output class="stream-result">{@stream_state}:{@byte_count}:{@checksum}</output>
      <output class="whole-read">{@whole_state}</output>
    }
  end
end
