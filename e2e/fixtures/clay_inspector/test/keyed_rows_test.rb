Mochi::Test.test("retains expanded station state and returns focus after removal") do
  mount "record-inspector"
  harbor = "[data-station='01'] >>> [data-id='01']"
  cafe = "[data-station='02'] >>> [data-id='02']"
  hide = "[data-station='01'] >>> [data-row-action='hide']"
  wait_for harbor
  focus harbor
  press "Space"
  assert_attribute harbor, "aria-expanded", "true"

  click "[data-action='reverse']"
  assert_attribute "station-row >>> [data-id]", "data-id", "03"
  assert_attribute harbor, "aria-expanded", "true"
  click "[data-action='reverse']"
  assert_attribute "station-row >>> [data-id]", "data-id", "01"
  assert_attribute harbor, "aria-expanded", "true"
  focus harbor
  press "Tab"
  assert_focused hide
  press "Space"
  assert_focused cafe
  assert_attribute "station-row >>> [data-id]", "data-id", "02"
  press "Space"
  assert_text "[data-view='selection']", "Selected station 02"
  remount
  wait_for harbor
  assert_attribute harbor, "aria-expanded", "false"
end
