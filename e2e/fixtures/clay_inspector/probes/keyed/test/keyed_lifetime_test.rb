Mochi::Test.test("validates row keys and disposes only the removed Ruby instances") do
  mount "keyed-probe"
  alder = "[data-primary='a'] >>> [data-row]"
  birch = "[data-primary='b'] >>> [data-row]"
  cedar = "[data-primary='c'] >>> [data-row]"
  other = "[data-secondary='other'] >>> [data-row]"
  first = "[data-primary] >>> [data-row]"
  wait_for alder
  wait_for birch
  wait_for cedar
  wait_for other
  focus alder
  press "Space"
  assert_focused alder
  assert_text first, "Cedar / 0"
  assert_text alder, "Alder / 1"
  assert_text other, "Other / 0"
  click other
  assert_text other, "Other / 1"
  assert_text "[data-last]", "Other list"
  focus birch
  press "Tab"
  assert_focused alder

  expect_error 'duplicate list key "1" at rows 1 and 2'
  click "[data-duplicate]"
  assert_text first, "Cedar / 0"
  assert_text alder, "Alder / 1"
  assert_text other, "Other / 1"
  assert_text "[data-unmounts]", "Unmounts 0"

  click "[data-replace]"
  assert_text alder, "Updated Alder / 1"
  focus alder
  press "Space"
  assert_focused alder
  assert_text first, "Updated Alder / 2"
  assert_text "[data-last]", "Updated Alder"
  press "Tab"
  assert_focused birch
  press "Space"
  assert_focused cedar
  assert_text "[data-last]", "Birch"
  assert_text "[data-unmounts]", "Unmounts 1"

  remount
  wait_for alder
  assert_text alder, "Alder / 0"
  assert_text birch, "Birch / 0"
  assert_text other, "Other / 0"
  assert_text "[data-unmounts]", "Unmounts 4"
end
