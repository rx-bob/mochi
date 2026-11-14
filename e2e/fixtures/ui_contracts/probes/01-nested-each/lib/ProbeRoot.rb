
class ProbeRoot
  @tag_name = "probe-root"

  @groups
  def initialize
    @groups = [{"name" => "Group", "items" => [{"name" => "Alpha"}]}]
  end

  def html
    %Q{{each @groups as group}<section><h2>{group["name"]}</h2>{each group["items"] as item}<p>{item["name"]}</p>{end}</section>{end}}
  end
end
