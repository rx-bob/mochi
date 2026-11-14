
class ProbeRoot
  @tag_name = "probe-root"

  @records
  def initialize
    @records = []
    index = 0
    while index < 480
      @records << {"id" => "record-#{index}", "message" => "Record #{index}", "attributes" => [{"name" => "source", "value" => "worker-#{index % 4}"}]}
      index += 1
    end
  end

  def html
    %Q{<output>{@records.length}</output>}
  end
end
