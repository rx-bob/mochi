class FileContract
  @tag_name = "file-contract"
  @input_files
  @drop_files

  def initialize
    @input_files = []
    @drop_files = []
  end

  def receive_input(event)
    @input_files = event["files"]
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
    }
  end
end
