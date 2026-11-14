Mochi::Test.test("Unix seconds preserve fractions, pre-epoch floor, UTC identity, and computed values") do
  mount "probe-root"
  assert_text "output", "-1.25:-2:true"
  assert_text ".computed", "1.25:1"
  assert_text ".bounds", "-8640000000000:8640000000000"
  assert_text ".roundtrips", "true,true,true,true,true,true"
  click ".update"
  assert_text ".computed", "-0.125:-1"
end

Mochi::Test.test("unsupported time forms report errors and permit a valid next event") do
  mount "probe-root"
  {
    ".wrong-type" => "Time.at expects Integer or Float Unix seconds",
    ".nonfinite" => "non-finite float",
    ".out-of-range" => "Time.at seconds must be between",
    ".extra-arguments" => "wrong number of arguments",
    ".calendar-constructor" => "unknown method",
    ".invalid-zone" => "invalid date options",
    ".computed-clock" => "computed evaluation must not mutate state or emit host effects"
  }.each do |selector, error|
    expect_error error
    click selector
    assert_text "output", "-1.25:-2:true"
    click ".valid"
    assert_text "output", "-1.25:-2:true"
  end
end
