class ProbeRoot
  @tag_name = "probe-root"
  prop :open, Integer, default: 1
  @rows

  def initialize
    @rows = [
      {"id" => "a", "name" => "Alpha", "enabled" => true, "radius" => 4, "letters" => ["x", "y"]},
      {"id" => "b", "name" => "Beta", "enabled" => false, "radius" => 8, "letters" => ["z"]}
    ]
  end

  def toggle
    @open = @open == 1 ? 0 : 1
  end

  def inactive
    MissingValue::VALUE
  end

  def html
    %Q{
      <button class="toggle" onclick="{toggle}">Toggle</button>
      <table><tbody>{if @open == 1}
        {each @rows as row, key: row["id"]}
          <tr data-id="{row['id']}">{if row["enabled"]}<td>{row["name"]}</td>{else}<td>Disabled {row["name"]}</td>{end}</tr>
        {end}
      {else}<tr class="closed"><td>Closed</td></tr>{end}</tbody></table>
      <select>{if @open == 1}
        {each @rows as row, key: row["id"]}
          {if row["enabled"]}<option value="{row['id']}">{row["name"]}</option>{else}<option value="{row['id']}" disabled>Disabled {row["name"]}</option>{end}
        {end}
      {else}<option>Closed</option>{end}</select>
      <svg><g>{if @open == 1}
        {each @rows as row, key: row["id"]}
          {if row["enabled"]}<circle data-id="{row['id']}" r="{row['radius']}"></circle>{else}<rect data-id="{row['id']}" width="{row['radius']}" height="2"></rect>{end}
        {end}
      {else}<text>Closed</text>{end}</g>
      <foreignObject width="100" height="60">{if @open == 1}
        {each @rows as row}<p>{row["name"]}</p>{end}
      {else}<p>Closed</p>{end}</foreignObject></svg>
      {each @rows as row, ri}
        <section class="scope" data-id="{row['id']}">
          {if RowGate.enabled?(row)}
            {each row["letters"] as row, ci}<i>{row}:{index}</i>{end}
          {else}<b>{row["name"]}:{index}</b>{end}
          <output>{row["name"]}:{index}</output>
          {if false}<span>{inactive}</span>{end}
        </section>
      {end}
    }
  end
end
