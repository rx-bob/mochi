Mochi::Test.test("updates one typed details panel and routes its confirmation") do
  mount "record-inspector"
  click "[data-action='details']"
  opened = "station-details >>> [data-detail='opened']"
  pair = "station-details >>> [data-detail='pair']"
  snapshot = "station-details >>> [data-detail='snapshot']"
  confirm = "station-details >>> [data-detail='confirm']"

  wait_for pair
  assert_text opened, "Showing details for station 101: parent"
  assert_text pair, "1: Harbor"
  assert_text snapshot, "parent / 0"
  click confirm
  assert_text "[data-confirmation='status']", "101: Harbor / 1 / parent"
  assert_text snapshot, "child / 1"

  cafe = "[data-station='02'] >>> [data-id='02']"
  wait_for cafe
  click cafe
  assert_text pair, "2: Café"
  assert_text opened, "Showing details for station 101: parent"
  assert_text snapshot, "child / 1"
  click confirm
  assert_text "[data-confirmation='status']", "102: Café / 2 / parent"

  click "[data-action='details']"
  assert_text "[data-view='selection']", "Selected station 02"
  click "[data-action='details']"
  wait_for pair
  assert_text opened, "Showing details for station 102: parent"
  assert_text snapshot, "parent / 0"
  assert_text pair, "2: Café"
end
