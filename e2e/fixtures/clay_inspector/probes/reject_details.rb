# Inject invalid inputs into a disposable inspector checkout for both runners.
project = ARGV.fetch(0)
root = File.join(project, "lib", "RecordInspector.rb")
child = File.join(project, "lib", "StationDetails.rb")
File.write(root, File.read(root).sub('station-id="{StationNumbers.id(@selected)}"', 'station-id="{@selected == "02" ? nil : StationNumbers.id(@selected)}"'))
File.write(child, File.read(child).sub('id: @station_id, name:', 'id: "bad", name:'))
File.write(File.join(project, "test", "rejected_details_test.rb"), <<~'TEST')
  Mochi::Test.test("rejects invalid details inputs and keeps the inspector interactive") do
    mount "record-inspector"
    details = "[data-action='details']"
    pair = "station-details >>> [data-detail='pair']"
    click details
    wait_for pair
    expect_error 'event "confirm" payload field "id" expects integer'
    click "station-details >>> [data-detail='confirm']"
    assert_text "[data-confirmation='status']", "No station confirmed"

    cafe = "[data-station='02'] >>> [data-id='02']"
    wait_for cafe
    expect_error 'prop "station_id" is required'
    click cafe
    assert_text pair, "1: Harbor"
    click details
    expect_error 'prop "station_id" is required'
    click details
    assert_text "[data-view='selection']", "Selected station 02"

    click "[data-station='03'] >>> [data-id='03']"
    assert_text "[data-view='selection']", "Selected station 03"
    click details
    click details
    wait_for pair
    assert_text pair, "3: West"
  end
TEST
