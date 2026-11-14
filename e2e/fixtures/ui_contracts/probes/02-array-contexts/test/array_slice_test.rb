Mochi::Test.test("array slices match Ruby in initialization, helpers, events, and templates") do
  mount "probe-root"
  assert_text ".initial", [1, 2, 3, 4].slice(1, 2).join(",")
  assert_text ".stored-initial", [1, 2, 3, 4][1, 2].join(",")
  assert_text ".helper", "2,3"
  assert_text ".template", "2,3"
  assert_text ".scalar", "1:4:2"
  assert_text ".alias", "9"
  pairs = [[1, 2], [-2, 9], [-4, 2], [-5, 2], [0, -1], [1, 0],
           [4, 2], [4, 0], [5, 0], [0, 9223372036854775807],
           [-9223372036854775807 - 1, 2]]
  expected = pairs.flat_map do |start, length|
    array = [1, 2, 3, 4].slice(start, length)
    value = array.nil? ? "nil" : "#{array.length}:#{array.join(',')}"
    [value, value]
  end.join("|")
  assert_text ".boundaries", expected
  click ".valid"
  assert_text ".event", "3,4"
  assert_text ".original", "1,2,3,4"
end

Mochi::Test.test("invalid array arguments report errors and later slicing works") do
  mount "probe-root"
  [".no-args", ".extra-args"].each do |selector|
    expect_error "wrong number of arguments"
    click selector
    click ".valid"
    assert_text ".event", "3,4"
  end
  [".bad-start", ".bad-length", ".bad-scalar"].each do |selector|
    expect_error "type mismatch"
    click selector
    click ".valid"
    assert_text ".event", "3,4"
  end
end

Mochi::Test.test("slice exhaustion names slots, preserves output, and permits a smaller page") do
  mount "probe-root"
  click ".prepare-big"
  assert_text ".big-count", "5000"
  expect_error "scratch slots exhausted"
  click ".exhaust"
  assert_text ".last", "unchanged"
  assert_text ".big-count", "5000"
  click ".small"
  assert_text ".last", "4998,4999"
end
