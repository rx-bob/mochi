Mochi::Test.test("graph geometry follows ordinary Ruby state across edits and recreation") do
  mount "editable-graph-root"
  assert_text ".node-count", "4"
  assert_text ".edge-count", "3"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 180 50"
  assert_attribute "[data-edge='bc']", "d", "M 180 50 L 180 150"
  assert_attribute "[data-edge='cd']", "d", "M 180 150 L 320 150"
  assert_attribute ".scene", "transform", "translate(0 0)"
  click ".move"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 200 60"
  assert_attribute "[data-edge='bc']", "d", "M 200 60 L 180 150"
  assert_attribute "[data-edge='cd']", "d", "M 180 150 L 320 150"
  assert_attribute "[data-node='b']", "transform", "translate(200 60)"
  assert_attribute "[data-node='b'] circle", "r", "13"
  click ".reorder"
  assert_attribute ".edge:first-of-type", "data-edge", "cd"
  click ".remove"
  assert_text ".edge-count", "2"
  click ".restore"
  assert_text ".edge-count", "3"
  assert_attribute "[data-edge='bc']", "d", "M 200 60 L 180 150"
  click ".pan"
  assert_attribute ".scene", "transform", "translate(10 5)"
  3.times do
    click ".toggle"
    assert_text ".closed", "Graph closed"
    click ".toggle"
    assert_attribute "[data-edge='bc']", "d", "M 200 60 L 180 150"
    assert_attribute "[data-edge='bc']", "marker-end", "url(#arrowhead)"
    assert_attribute ".scene", "transform", "translate(10 5)"
  end
  remount "editable-graph-root"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 180 50"
end

Mochi::Test.test("initially closed graph mounts current geometry without placeholders") do
  mount "editable-graph-root", open: false
  assert_text ".closed", "Graph closed"
  click ".move"
  click ".pan"
  click ".toggle"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 200 60"
  assert_attribute ".scene", "transform", "translate(10 5)"
  assert_attribute "[data-node='b'] circle", "r", "13"
end

Mochi::Test.test("graph node surfaces and nested labels select through handler data") do
  mount "editable-graph-root"
  click "[data-node='b'] circle"
  assert_text ".selected-id", "b"
  click "[data-node='c'] text"
  assert_text ".selected-id", "c"
  click "[data-node='b'] text"
  assert_text ".selected-id", "b"
  click ".move"
  click "[data-node='c'] circle"
  assert_text ".selected-id", "c"
  click "[data-node='b'] text"
  assert_text ".selected-id", "b"
  click ".toggle"
  click ".toggle"
  click "[data-node='a'] text"
  assert_text ".selected-id", "a"
end

Mochi::Test.test("graph retains exactly the last forty edits and replays isolated snapshots") do
  mount "editable-graph-root"
  45.times do |index|
    click ".move"
    edit = index + 1
    assert_text ".undo-count", [edit, 40].min.to_s
    assert_text ".redo-count", "0"
    assert_attribute "[data-node='b']", "transform", "translate(#{180 + 20 * edit} #{50 + 10 * edit})"
    assert_text "[data-node='b'] text", "Review"
    assert_attribute "[data-edge='ab']", "d", "M 40 50 L #{180 + 20 * edit} #{50 + 10 * edit}"
    assert_attribute "[data-edge='bc']", "d", "M #{180 + 20 * edit} #{50 + 10 * edit} L 180 150"
  end
  40.times do |index|
    click ".undo"
    edit = 44 - index
    assert_text ".undo-count", (39 - index).to_s
    assert_text ".redo-count", (index + 1).to_s
    assert_attribute "[data-node='b']", "transform", "translate(#{180 + 20 * edit} #{50 + 10 * edit})"
    assert_attribute "[data-node='b'] circle", "r", (12 + edit).to_s
    assert_text "[data-node='b'] text", "Review"
    assert_attribute "[data-edge='ab']", "d", "M 40 50 L #{180 + 20 * edit} #{50 + 10 * edit}"
    assert_attribute "[data-edge='bc']", "d", "M #{180 + 20 * edit} #{50 + 10 * edit} L 180 150"
  end
  click ".undo"
  assert_attribute "[data-node='b']", "transform", "translate(280 100)"
  40.times do |index|
    click ".redo"
    edit = index + 6
    assert_text ".undo-count", (index + 1).to_s
    assert_text ".redo-count", (39 - index).to_s
    assert_attribute "[data-node='b']", "transform", "translate(#{180 + 20 * edit} #{50 + 10 * edit})"
    assert_attribute "[data-node='b'] circle", "r", (12 + edit).to_s
    assert_text "[data-node='b'] text", "Review"
    assert_attribute "[data-edge='ab']", "d", "M 40 50 L #{180 + 20 * edit} #{50 + 10 * edit}"
    assert_attribute "[data-edge='bc']", "d", "M #{180 + 20 * edit} #{50 + 10 * edit} L 180 150"
  end
  click ".redo"
  assert_text ".undo-count", "40"
  click ".undo"
  click ".add-node"
  assert_text ".redo-count", "0"
  assert_text ".undo-count", "40"
  assert_text "[data-node='n1'] text", "Node 1"
  click ".redo"
  assert_attribute "[data-node='b']", "transform", "translate(1060 490)"
  click ".undo"
  assert_text ".node-count", "4"
  click ".undo"
  assert_attribute "[data-node='b']", "transform", "translate(1040 480)"
  click ".redo"
  click ".redo"
  assert_text "[data-node='n1'] text", "Node 1"
  assert_attribute "[data-node='b']", "transform", "translate(1060 490)"
end

Mochi::Test.test("node removal restores connected paths and deterministic add IDs through history") do
  mount "editable-graph-root"
  click "[data-node='b'] circle"
  click ".remove-node"
  assert_text ".node-count", "3"
  assert_text ".edge-count", "1"
  assert_attribute ".edge", "data-edge", "cd"
  click ".restore"
  assert_text ".edge-count", "1"
  assert_text ".undo-count", "1"
  click ".undo"
  assert_text ".node-count", "4"
  assert_text ".edge-count", "3"
  assert_text ".selected-id", "b"
  assert_text "[data-node='b'] text", "Review"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 180 50"
  click ".redo"
  assert_text ".node-count", "3"
  click ".add-node"
  assert_text ".selected-id", "n1"
  assert_text "[data-node='n1'] text", "Node 1"
  click ".undo"
  click ".add-node"
  assert_text ".redo-count", "0"
  assert_text ".selected-id", "n1"
  click ".add-node"
  assert_text "[data-node='n2'] text", "Node 2"
  click ".remove-node"
  click ".undo"
  assert_text "[data-node='n2'] text", "Node 2"
  assert_text ".edge-count", "1"
end

Mochi::Test.test("captured drag outside the graph commits once and undo restores geometry") do
  mount "editable-graph-root"
  pointer_press "[data-node='b'] circle"
  assert_text ".drag-state", "dragging"
  pointer_move_by 260, 180, steps: 24
  assert_attribute "[data-node='b']", "transform", "translate(440 230)"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 440 230"
  assert_attribute "[data-edge='bc']", "d", "M 440 230 L 180 150"
  assert_text ".undo-count", "0"
  pointer_release
  assert_text ".drag-state", "idle"
  assert_text ".terminal", "up"
  assert_text ".undo-count", "1"
  assert_pointer_capture_released
  click ".undo"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  assert_attribute "[data-edge='ab']", "d", "M 40 50 L 180 50"
  click ".redo"
  assert_attribute "[data-node='b']", "transform", "translate(440 230)"
  assert_text ".undo-count", "1"
end

Mochi::Test.test("cancel loss branch removal and unmount leave no graph gesture or extra history") do
  mount "editable-graph-root"
  pointer_press "[data-node='b'] circle"
  pointer_release
  assert_text ".undo-count", "0"
  3.times do
    pointer_press "[data-node='b'] circle"
    pointer_move_by 60, 30, steps: 8
    pointer_cancel
    assert_text ".drag-state", "idle"
    # Synthetic cancellation can surface as capture loss in WebKit. Both end
    # the gesture without committing it; the branch below checks lost_capture.
    assert_text ".undo-count", "0"
    assert_attribute "[data-node='b']", "transform", "translate(180 50)"
    assert_attribute "[data-edge='ab']", "d", "M 40 50 L 180 50"
    assert_pointer_capture_released
    pointer_press "[data-node='b'] circle"
    pointer_move_by 40, 20, steps: 8
    pointer_lose_capture
    assert_text ".drag-state", "idle"
    assert_text ".terminal", "lost_capture"
    assert_text ".undo-count", "0"
    assert_attribute "[data-node='b']", "transform", "translate(180 50)"
    assert_pointer_capture_released
  end
  pointer_press "[data-node='b'] circle"
  pointer_move_by 20, 10
  click ".toggle"
  assert_text ".drag-state", "idle"
  assert_text ".undo-count", "0"
  assert_pointer_capture_released
  pointer_release
  click ".toggle"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  pointer_press "[data-node='b'] circle"
  pointer_move_by 30, 20
  unmount
  assert_pointer_capture_released
  remount "editable-graph-root"
  assert_text ".drag-state", "idle"
  assert_text ".undo-count", "0"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
end

Mochi::Test.test("canceled drags preserve redo while a completed new drag clears it") do
  mount "editable-graph-root"
  click ".move"
  click ".undo"
  assert_text ".redo-count", "1"
  pointer_press "[data-node='b'] circle"
  pointer_move_by 30, 20
  pointer_cancel
  assert_text ".redo-count", "1"
  assert_text ".undo-count", "0"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  click ".redo"
  assert_attribute "[data-node='b']", "transform", "translate(200 60)"
  click ".undo"
  pointer_press "[data-node='b'] circle"
  pointer_move_by 60, 30
  pointer_release
  assert_text ".redo-count", "0"
  assert_text ".undo-count", "1"
  assert_attribute "[data-node='b']", "transform", "translate(240 80)"
  click ".undo"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  pointer_press "[data-node='b'] circle"
  pointer_move_by 40, 20
  pointer_move_by -40, -20
  pointer_release
  assert_text ".undo-count", "0"
  assert_text ".redo-count", "1"
  assert_pointer_capture_released
end

Mochi::Test.test("owned graph shortcuts undo redo without intercepting note editing") do
  mount "editable-graph-root"
  click ".move"
  focus ".viewport"
  press "Control+z"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  press "Control+Shift+z"
  assert_attribute "[data-node='b']", "transform", "translate(200 60)"
  press "Meta+z"
  assert_attribute "[data-node='b']", "transform", "translate(180 50)"
  press "Meta+Shift+z"
  assert_attribute "[data-node='b']", "transform", "translate(200 60)"
  focus ".graph-note"
  fill ".graph-note", "Draft note"
  press "Control+z"
  assert_attribute "[data-node='b']", "transform", "translate(200 60)"
  assert_text ".undo-count", "1"
  assert_text ".shortcut-error", ""
  remount "editable-graph-root"
  click ".move"
  focus ".viewport"
  press "Control+z"
  assert_text ".undo-count", "0"
  assert_text ".redo-count", "1"
end
