binary_bytes = (0..255).to_a
Mochi::Test.test("bounded file text parses JSON without losing signed64 integers") do
  mount "json-file-contract"
  document = '{"id":9007199254740993,"values":[null,true,false,"é😀\\n"]}'
  select_files ".json-file", files: [{ name: "record.json", bytes: document, type: "application/json" }]
  wait_for_settled
  assert_text ".json-result", document
  select_files ".json-file", files: [{ name: "oversized.json", bytes: " " * 48001 }]
  wait_for_settled
  assert_text ".json-result", "error:file exceeds configured whole-file read limit"
  select_files ".json-file", files: [{ name: "next.json", bytes: '{"ok":true}' }]
  wait_for_settled
  assert_text ".json-result", '{"ok":true}'
end

binary_checksum = 0
binary_bytes.each { |byte| binary_checksum = (binary_checksum * 31 + byte) % 2147483647 }
large_bytes = "z" * 65537
large_checksum = 0
large_bytes.each_byte { |byte| large_checksum = (large_checksum * 31 + byte) % 2147483647 }

Mochi::Test.test("file input reads exact binary bytes and strict UTF-8 text") do
  mount "file-contract"
  select_files ".file-input", files: [{ name: "all-bytes.bin", type: "application/octet-stream", bytes: binary_bytes }]
  wait_for_settled
  assert_state ".whole-read", "bytes:256:#{binary_checksum}"

  select_files ".file-input", files: [{ path: "fixtures/utf8_boundary.txt", type: "text/plain" }]
  wait_for_settled
  assert_state ".whole-read", "text:8195:€"

  select_files ".file-input", files: [{ name: "empty.bin", bytes: [] }]
  wait_for_settled
  assert_state ".whole-read", "bytes:0:0"
end

Mochi::Test.test("file drops stream oversized files and report errors and cancellation") do
  mount "file-contract"
  drop_files ".file-drop", files: [{ name: "large.bin", bytes: large_bytes, delay_ms: 1 }]
  wait_for_settled
  assert_state ".stream-result", "eof:65537:#{large_checksum}"

  drop_files ".file-drop", files: [{ name: "broken.bin", bytes: "bad", fail_read: true }]
  wait_for_settled
  assert_state ".whole-read", "error:synthetic file read failure"

  drop_files ".file-drop", files: [{ name: "cancel.bin", bytes: "pending", delay_ms: 500 }]
  click ".cancel-stream"
  assert_state ".whole-read", "cancelled"
  wait_for_settled
end

Mochi::Test.test("structured drag actions deliver Ruby values and state") do
  mount "file-drag-test-root"
  drag ".drag-source", ".drag-target"
  wait_for_settled
  assert_state ".drag-state", "false:3:move"
end
