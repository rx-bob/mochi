binary_bytes = (0..255).to_a
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
