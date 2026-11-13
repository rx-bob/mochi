require_relative "../lib/RecordData"

Mochi::Test.test("helper constants, receivers, and next match direct Ruby in every context") do
  mount "probe-root"
  value = "#{RecordData::BASE}:#{RecordData.base_ms}"
  assert_text ".initial", value
  assert_text ".method", value
  assert_text ".template", value
  assert_text ".other", "99:99"
  assert_text ".built", RecordData.build
  assert_text ".template-built", RecordData.build
  click ".update"
  assert_text ".event", "#{value}:#{RecordData.build}"
end

Mochi::Test.test("missing helper references report their names and allow recovery") do
  mount "probe-root"
  expect_error "unknown constant RecordData::MISSING"
  click ".missing-constant"
  click ".update"
  assert_text ".event", "#{RecordData::BASE}:#{RecordData.base_ms}:#{RecordData.build}"
  expect_error "RecordData#missing: unknown method"
  click ".missing-method"
  click ".update"
  assert_text ".event", "#{RecordData::BASE}:#{RecordData.base_ms}:#{RecordData.build}"
end
