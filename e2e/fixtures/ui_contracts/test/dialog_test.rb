Mochi::Test.test("dialog recipe traps keyboard focus and confirms through its typed event") do
  mount "dialog-recipe-root"
  focus ".open"
  press "Enter"
  wait_for_settled

  assert_focused "confirm-dialog >>> .cancel"
  press "Shift+Tab"
  assert_focused "confirm-dialog >>> .confirm"
  press "Tab"
  assert_focused "confirm-dialog >>> .cancel"
  press "Tab"
  assert_focused "confirm-dialog >>> .confirm"
  press "Enter"

  assert_text ".result", "confirmed:true"
  assert_focused ".open"
end

Mochi::Test.test("dialog recipe updates safe text, cancels with Escape, and reopens cleanly") do
  mount "dialog-recipe-root"
  focus ".open"
  press "Enter"
  wait_for_settled
  assert_text "confirm-dialog >>> .title", "Delete draft?"
  assert_text "confirm-dialog >>> .message", "This action removes the current draft."

  click ".update-data"
  assert_text "confirm-dialog >>> .title", %q(Delete "Draft" <img data-injected="yes">?)
  assert_text "confirm-dialog >>> .message", %q(User text: <strong>keep this literal</strong> & continue)
  assert_focused "confirm-dialog >>> .cancel"

  press "Escape"
  assert_text ".result", "cancelled:escape"
  assert_focused ".open"

  press "Enter"
  wait_for_settled
  assert_focused "confirm-dialog >>> .cancel"
  press "Escape"
  assert_text ".result", "cancelled:escape"
  assert_focused ".open"
end

Mochi::Test.test("dialog recipe uses a live fallback when its opener disappears") do
  mount "dialog-recipe-root"
  focus ".open"
  press "Enter"
  wait_for_settled
  assert_focused "confirm-dialog >>> .cancel"

  click ".remove-trigger"
  assert_text ".opener-removed", "Opener removed"
  click "confirm-dialog >>> .cancel"

  assert_text ".result", "cancelled:button"
  assert_focused ".fallback"
  press "Escape"
  assert_text ".result", "cancelled:button"
  assert_focused ".fallback"
end
