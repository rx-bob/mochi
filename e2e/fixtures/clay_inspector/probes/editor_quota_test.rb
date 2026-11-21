Mochi::Test.test("keeps the draft and focus after a rejected save, then retries") do
  mount "record-inspector"
  row = "[data-station='02'] >>> [data-id='02']"
  edit = "[data-action='edit']"
  name = "station-editor >>> [data-view='name-field']"
  open = "station-editor >>> [data-view='open-field']"
  save = "station-editor >>> [data-action='save']"
  message = "station-editor >>> [data-view='editor-message']"
  oversized = "N" * 4100

  wait_for row
  click row
  click edit
  wait_for name
  fill name, "Café Saved"
  focus save
  press "Space"
  assert_text row, "Café Saved observation from the northern coastal monitoring station"

  click edit
  wait_for name
  fill name, oversized
  focus open
  press "Space"
  focus save
  expect_error "quota"
  press "Space"
  assert_focused save
  assert_value name, oversized
  assert_checked open, true
  assert_text message, "Could not save station. Try again."
  assert_text row, "Café Saved observation from the northern coastal monitoring station"

  remount
  wait_for row
  click row
  click edit
  wait_for name
  assert_value name, "Café Saved"
  assert_checked open, false
  fill name, "Café Retried"
  focus open
  press "Space"
  focus save
  press "Space"
  assert_focused edit
  remount
  wait_for row
  click row
  click edit
  wait_for name
  assert_value name, "Café Retried"
  assert_checked open, true
end
