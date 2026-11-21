Mochi::Test.test("commits portable edits before Ruby handlers run") do
  mount "station-editor"
  name = "[data-field='name']"
  open = "[data-field='open']"
  history = "[data-view='history']"

  assert_value name, "Harbor"
  fill name, "Café"
  assert_value name, "Café"
  assert_text history, "input=Café"

  click open
  assert_text history, "input=Café | change=true"
  focus open
  press "Space"
  assert_text history, "input=Café | change=true | change=false"

  click "[data-action='lock']"
  click open
  assert_text history, "input=Café | change=true | change=false"
  assert_value name, "Café"

  click "[data-action='lock']"
  fill name, "West ridge"
  assert_text history, "input=Café | change=true | change=false | input=West ridge"
end
