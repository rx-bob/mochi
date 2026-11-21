Mochi::Test.test("keeps the confirmed value after quota failure and recovers") do
  mount "station-storage"
  click "[data-action='save']"
  expect_error "quota"
  click "[data-action='quota']"
  assert_text "[data-view='receipt']", "same_tab quota label label 3"
  assert_text "[data-view='mirror']", "label"
  click "[data-action='empty']"
  assert_text "[data-view='receipt']", "same_tab ok empty label 4"
  assert_text "[data-view='mirror']", "empty"
end
