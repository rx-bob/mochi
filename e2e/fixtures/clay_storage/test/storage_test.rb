Mochi::Test.test("confirms storage writes and distinguishes absence from empty text") do
  mount "station-storage"
  assert_text "[data-view='boot']", "Default"
  assert_text "[data-view='receipt']", "initial ok absent absent 1"
  click "[data-action='save']"
  assert_text "[data-view='receipt']", "same_tab ok label absent 2"
  assert_text "[data-view='mirror']", "label"
  click "[data-action='equal']"
  assert_text "[data-view='receipt']", "same_tab ok label absent 2"
  remount
  assert_text "[data-view='boot']", "label"
  assert_text "[data-view='receipt']", "initial ok label absent 1"

  click "[data-action='empty']"
  assert_text "[data-view='receipt']", "same_tab ok empty label 2"
  assert_text "[data-view='mirror']", "empty"
  remount
  assert_text "[data-view='boot']", "empty"
  click "[data-action='remove']"
  assert_text "[data-view='receipt']", "same_tab ok absent empty 2"
  assert_text "[data-view='mirror']", "Default"
  click "[data-action='remove']"
  assert_text "[data-view='receipt']", "same_tab ok absent empty 2"
  remount
  assert_text "[data-view='boot']", "Default"
end
