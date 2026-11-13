Mochi::Test.test("pointer drag coalesces moves and releases at latest position") do
  mount "pointer-contracts-root"
  pointer_press ".handle"
  assert_text ".drag-state", "dragging"
  pointer_move_by 120, 80, steps: 24
  assert_text ".delta", "120,80"
  pointer_release
  assert_text ".drag-state", "idle"
  assert_text ".terminal", "up"
  assert_pointer_capture_released
end

Mochi::Test.test("cancel, lost capture, and unmount clear gesture ownership") do
  mount "pointer-contracts-root"
  pointer_press ".handle"
  pointer_move_by 50, 20, steps: 12
  pointer_cancel
  assert_text ".drag-state", "idle"
  assert_text ".terminal", "cancel"
  assert_pointer_capture_released

  pointer_press ".handle"
  pointer_lose_capture
  assert_text ".drag-state", "idle"
  assert_pointer_capture_released

  pointer_press ".handle"
  unmount
  assert_pointer_capture_released
  remount "pointer-contracts-root"
  assert_text ".drag-state", "idle"
end
