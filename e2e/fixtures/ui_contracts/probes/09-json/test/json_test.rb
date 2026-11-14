Mochi::Test.test("JSON rejects invalid values without publishing partial results and recovers") do
  mount "probe-root"
  expected = '{"id":9007199254740993}'
  assert_text "output", expected
  assert_text ".computed", expected
  {
    ".malformed" => "invalid JSON or UTF-8",
    ".cycle" => "cyclic JSON value",
    ".unsupported" => "unsupported JSON value",
    ".nonfinite" => "non-finite float",
    ".too-deep" => "JSON byte or nesting limit exceeded",
    ".too-large" => "JSON byte or nesting limit exceeded"
  }.each do |selector, error|
    expect_error error
    click selector
    assert_text "output", expected
    click ".valid"
    assert_text "output", expected
    assert_text ".computed", expected
  end
end
