Mochi::Test.test("inspector mounts 480 structured records with 12 stable first-page IDs") do
  mount "inspector-root"
  assert_text ".total", "480"
  assert_text ".matched", "480"
  assert_text ".visible-count", "12"
  assert_text ".page", "1"
  12.times do |index|
    id = index + 1
    assert_attribute ".record:nth-child(#{id})", "data-id", "record-#{id}"
    assert_text ".record:nth-child(#{id}) .message", "Record #{id} processed"
    assert_text ".record:nth-child(#{id}) .severity", id % 3 == 0 ? "warning" : "info"
  end
  click "[data-id='record-3'] button"
  assert_text ".selected-id", "record-3"
  assert_text ".selected-detail", "worker-3:3"
  assert_text ".selected-message", "Record 3 processed"
  assert_text ".selected-timestamp", "1794571200003"
  assert_text "[data-name='region'] dd", "zone-0"
  assert_text "[data-name='attempt'] dd", "4"
end

Mochi::Test.test("inspector pages, filters literally, and retains selection by ID") do
  mount "inspector-root"
  click ".next"
  assert_text ".page", "2"
  assert_attribute ".record:first-child", "data-id", "record-13"
  click "[data-id='record-13'] button"
  click ".next"
  assert_text ".page", "3"
  assert_attribute ".record:first-child", "data-id", "record-25"
  assert_attribute ".record:last-child", "data-id", "record-36"
  fill ".filter", "Record 1"
  assert_text ".page", "1"
  assert_text ".matched", "111"
  assert_attribute ".record:first-child", "data-id", "record-1"
  assert_attribute ".record:last-child", "data-id", "record-100"
  assert_text ".selected-id", "record-13"
  assert_text ".selected-detail", "worker-1:13"
  9.times { click ".next" }
  assert_text ".page", "10"
  assert_text ".visible-count", "3"
  assert_attribute ".record:first-child", "data-id", "record-197"
  assert_attribute ".record:last-child", "data-id", "record-199"
  click ".next"
  assert_text ".page", "10"
  fill ".filter", ""
  click ".next"
  assert_text ".page", "2"
  fill ".filter", "Record"
  assert_text ".page", "1"
  assert_attribute ".record:first-child", "data-id", "record-1"
  fill ".filter", "Record 480 "
  assert_text ".visible-count", "1"
  assert_attribute ".record:first-child", "data-id", "record-480"
  assert_text ".selected-id", "record-13"
  fill ".filter", ".*"
  assert_text ".matched", "0"
  assert_text ".visible-count", "0"
  click ".previous"
  assert_text ".page", "1"
  fill ".filter", ""
  assert_text ".visible-count", "12"
end

Mochi::Test.test("all forty pages retain twelve structured records and inspect the final record") do
  mount "inspector-root"
  40.times do |page|
    assert_text ".page", (page + 1).to_s
    assert_text ".visible-count", "12"
    12.times do |index|
      assert_attribute ".record:nth-child(#{index + 1})", "data-id", "record-#{page * 12 + index + 1}"
    end
    click ".next"
  end
  assert_text ".page", "40"
  click "[data-id='record-480'] .message"
  assert_text ".selected-detail", "worker-0:480"
  assert_text ".selected-timestamp", "1794571200480"
  assert_text "[data-name='region'] dd", "zone-0"
  assert_text "[data-name='attempt'] dd", "1"
end

Mochi::Test.test("bounded appends and removal clear evicted selection and clamp pages") do
  mount "inspector-root"
  click "[data-id='record-1'] .message"
  click ".toggle-details"
  assert_text ".details-hidden", "Details hidden"
  click ".toggle-details"
  assert_text ".selected-detail", "worker-1:1"
  click ".append"
  assert_text ".total", "480"
  assert_attribute ".record:first-child", "data-id", "record-2"
  assert_text ".selected-id", ""
  assert_text ".selected-detail", "No selection"
  5.times do |index|
    click ".append"
    assert_text ".total", "480"
    assert_attribute ".record:first-child", "data-id", "record-#{index + 3}"
    assert_text ".visible-count", "12"
  end
  fill ".filter", "Record 48"
  assert_text ".matched", "8"
  assert_attribute ".record:last-child", "data-id", "record-486"
  click "[data-id='record-486'] .message"
  assert_text ".selected-detail", "worker-2:486"
  click ".remove-selected"
  assert_text ".total", "479"
  assert_text ".matched", "7"
  assert_text ".selected-id", ""
  assert_text ".selected-detail", "No selection"
  click ".append"
  assert_text ".total", "480"
  assert_attribute ".record:last-child", "data-id", "record-487"
  fill ".filter", "Record 1"
  9.times { click ".next" }
  [198, 199].each do |id|
    click "[data-id='record-#{id}'] .message"
    click ".remove-selected"
  end
  assert_text ".page", "9"
  assert_text ".matched", "108"
  assert_text ".visible-count", "12"
  assert_attribute ".record:last-child", "data-id", "record-197"
  assert_text ".selected-detail", "No selection"
end

Mochi::Test.test("table rows select the same record from buttons, labels, and cells") do
  mount "inspector-root"
  click "[data-id='record-3'] button"
  assert_text ".selected-id", "record-3"
  click "[data-id='record-4'] .severity"
  assert_text ".selected-id", "record-4"
  click "[data-id='record-3'] .message"
  assert_text ".selected-id", "record-3"
  assert_text ".selected-detail", "worker-3:3"
  focus "[data-id='record-4'] button"
  press "Enter"
  assert_text ".selected-id", "record-4"
  click ".next"
  click "[data-id='record-13'] .message"
  assert_text ".selected-id", "record-13"
end
