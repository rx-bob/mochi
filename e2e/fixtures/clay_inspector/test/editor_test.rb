Mochi::Test.test("edits, validates, saves and reopens station 02") do
  mount "record-inspector"
  row = "[data-station='02'] >>> [data-id='02']"
  edit = "[data-action='edit']"
  name = "station-editor >>> [data-view='name-field']"
  open = "station-editor >>> [data-view='open-field']"
  save = "station-editor >>> [data-action='save']"
  cancel = "station-editor >>> [data-action='cancel']"
  message = "station-editor >>> [data-view='editor-message']"

  wait_for row
  focus row
  press "Space"
  focus edit
  press "Space"
  wait_for name
  assert_focused name
  assert_value name, "Café"
  assert_checked open, false
  assert_attribute save, "disabled", "true"
  checkpoint "editor-disabled"

  press "Tab"
  assert_focused open
  press "Space"
  assert_checked open, true
  fill name, "  "
  focus name
  press "Tab"
  press "Tab"
  assert_focused save
  press "Space"
  assert_text message, "Enter a station name."
  assert_attribute message, "aria-live", "polite"
  assert_attribute name, "aria-invalid", "true"
  assert_focused name
  checkpoint "editor-error"

  fill name, "Café North"
  assert_attribute name, "aria-invalid", "false"
  press "Tab"
  checkpoint "editor-checkbox-focus"
  press "Tab"
  assert_focused save
  checkpoint "editor-save-focus"
  press "Space"
  assert_focused edit
  assert_text row, "Café North observation from the northern coastal monitoring station"

  remount
  wait_for row
  assert_text row, "Café North observation from the northern coastal monitoring station"
  click row
  click edit
  wait_for name
  assert_focused name
  assert_value name, "Café North"
  assert_checked open, true
  press "Tab"
  press "Tab"
  assert_focused cancel
  press "Space"
  assert_focused edit

  click "[data-list='toggle']"
  wait_for "[data-station='24'] >>> [data-id='24']"
  focus "[data-station='24'] >>> [data-id='24']"
  press "Space"
  click edit
  wait_for name
  assert_value name, "Station 24"
  checkpoint "editor-scrolled"
end
