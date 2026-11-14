require 'json'

class JsonFileContract
  @tag_name = "json-file-contract"
  @result
  @handle

  def initialize
    @result = "idle"
  end

  def read_file(event)
    files = event["files"]
    return if files.length == 0
    @handle = files[0]["handle"]
    reader = MochiFiles.open(@handle)
    MochiFiles.read_text(reader, :read_complete)
  end

  def read_complete(result)
    MochiFiles.release(@handle)
    if !result["ok"]
      @result = "error:#{result['error']}"
      return
    end
    @result = JSON.generate(JSON.parse(result["value"]))
  end

  def html
    %Q{
      <input class="json-file" type="file" onchange="{read_file($event)}">
      <output class="json-result">{@result}</output>
    }
  end
end
