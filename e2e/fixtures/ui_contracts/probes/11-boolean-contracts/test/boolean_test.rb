Mochi::Test.test("Boolean event payloads retain runtime validation") do
  mount "probe-root"
  wait_for_settled
  assert_text "boolean-editor >>> output", "false:false"
  expect_error 'payload field "valid" expects boolean, got string'
  click "boolean-editor >>> .bad"
  assert_text ".calls", "0"
  assert_text ".seen", "none"
  click "boolean-editor >>> .good"
  assert_text ".calls", "1"
  assert_text ".seen", "false"
end
