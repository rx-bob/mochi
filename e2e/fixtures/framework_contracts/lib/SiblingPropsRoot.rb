class SiblingPropsRoot
  @tag_name = "sibling-props-root"

  def html
    %Q{
      <child-probe label="A" remaining="20" reset="r0" tone="normal"></child-probe>
      <child-probe label="B" remaining="21" reset="r1" tone="normal"></child-probe>
      <child-probe label="C" remaining="22" reset="r2" tone="normal"></child-probe>
      <child-probe label="D" remaining="23" reset="r3" tone="normal"></child-probe>
      <child-probe label="E" remaining="24" reset="r4" tone="normal"></child-probe>
    }
  end
end
