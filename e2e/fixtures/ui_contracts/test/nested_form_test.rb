Mochi::Test.test("nested form edits survive keyed moves and neighbor changes") do
  mount "nested-form-root"
  wait_for_settled
  assert_value "[data-field='a'] field-editor >>> .draft", "Alpha"
  assert_text "[data-field='b'] .validation", "Required Alias"
  assert_text "[data-field='c'] .validation", "Check City"
  assert_text "[data-field='d'] .quiet", "Optional Country"
  fill "[data-field='a'] field-editor >>> .draft", "My draft"
  assert_text "[data-field='a'] field-editor >>> .draft-validation", "Valid: My draft"
  assert_text ".last", "g1:a:0:0:My draft"
  click ".reorder"
  click ".reorder-fields"
  click ".insert"
  assert_value "[data-field='a'] field-editor >>> .draft", "My draft"
  click "[data-field='a'] .pick"
  assert_text ".last", "g1:a:1:2:picked"
  click ".remove"
  fill "[data-field='a'] field-editor >>> .draft", "After move"
  assert_text ".last", "g1:a:1:1:After move"
  assert_text ".events", "3"
  fill "[data-field='a'] field-editor >>> .draft", ""
  assert_text "[data-field='a'] field-editor >>> .draft-validation", "Required"
  click ".toggle-group"
  assert_text "[data-group='g1'] .group-disabled", "Disabled Identity"
  click ".fresh"
  click ".toggle-group"
  wait_for_settled
  assert_value "[data-field='a'] field-editor >>> .draft", "Fresh a"
  assert_text "[data-field='a'] field-editor >>> .mount-count", "1"
end

Mochi::Test.test("quoted expressions retain Ruby values across form contexts") do
  mount "nested-form-root"
  wait_for_settled
  assert_attribute ".quoted-static", "title", "Quoted title"
  assert_attribute "[data-field='a']", "title", "Name"
  click ".adversarial"
  label = %q(Label "' <img data-injected='yes'> & &quot; {end})
  assert_text ".quoted-static", label
  assert_attribute ".quoted-static", "title", label
  assert_attribute ".quoted-static", "data-alt", label
  assert_attribute ".quoted-static", "data-interpolated", "#{label}:}"
  assert_attribute ".quoted-static", "data-literal", "{literal}"
  assert_text ".quoted-branch", label
  assert_attribute ".quoted-branch", "title", label
  assert_attribute ".quoted-branch", "class", "quoted-branch active"
  assert_attribute ".quoted-branch", "data-entity", "\" #{label} &"
  assert_attribute "[data-field='a']", "title", label
  assert_attribute "[data-field='a']", "data-alt", " #{label} "
  assert_attribute "[data-field='a']", "data-literal", "{row}"
  assert_attribute "[data-field='a']", "data-entity", "\" #{label} &"
  assert_text "[data-field='a'] field-editor >>> .label", "Identity / #{label}"
  assert_attribute "[data-field='a'] .pick", "title", label
  click ".quoted-event"
  assert_text ".last", "#{label}:}"
  click ".quoted-escape"
  assert_text ".last", 'quote: "x"'
  click "[data-field='a'] .quoted-row-event"
  assert_text ".last", "Identity|#{label}"
  click ".toggle"
  click ".toggle"
  wait_for_settled
  assert_attribute ".quoted-branch", "title", label
  assert_text "[data-field='a'] field-editor >>> .label", "Identity / #{label}"
end

Mochi::Test.test("initially closed form recreates branches from current props") do
  mount "nested-form-root", open: 0
  assert_text ".closed", "Form closed"
  click ".fresh"
  click ".toggle"
  wait_for_settled
  assert_value "[data-field='a'] field-editor >>> .draft", "Fresh a"
  3.times do
    fill "[data-field='a'] field-editor >>> .draft", "Discarded draft"
    click ".toggle"
    assert_text ".closed", "Form closed"
    click ".toggle"
    wait_for_settled
    assert_value "[data-field='a'] field-editor >>> .draft", "Fresh a"
  end
  assert_text ".events", "3"
end
