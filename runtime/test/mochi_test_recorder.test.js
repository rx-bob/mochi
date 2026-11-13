const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const recorder = path.resolve(__dirname, "mochi_test_recorder.rb");

function withTestProject(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-test-recorder-"));
  const testDir = path.join(root, "test");
  fs.mkdirSync(path.join(testDir, "fixtures"), { recursive: true });
  fs.writeFileSync(path.join(testDir, "fixtures", "sample.txt"), "sample");
  try {
    run(root, testDir);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("Ruby recorder serializes file, drop, drag, and state actions with Ruby locations", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "files_test.rb");
    const plan = path.join(root, "plan.json");
    fs.writeFileSync(source, [
      'Mochi::Test.test("file and drag steps") do',
      '  select_files ".input", files: [{ name: "bytes.bin", bytes: [0, 255] }]',
      '  drop_files ".drop", files: [{ path: "fixtures/sample.txt", type: "text/plain" }]',
      '  drag ".source", ".target"',
      '  assert_state ".status", "ready"',
      '  expect_error "read failed"',
      "end",
    ].join("\n"));

    const result = spawnSync("ruby", [recorder, testDir, plan], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const steps = JSON.parse(fs.readFileSync(plan, "utf8")).tests[0].steps;
    assert.deepEqual(steps.map((step) => step.operation), [
      "select_files", "drop_files", "drag", "assert_state", "expect_error",
    ]);
    assert.deepEqual(steps[0].files[0].bytes, [0, 255]);
    assert.equal(steps[1].files[0].path, "fixtures/sample.txt");
    steps.forEach((step, index) => {
      assert.equal(step.source, source);
      assert.equal(step.line, index + 2);
    });
  });
});

test("Ruby recorder rejects invalid file setup at the calling Ruby line", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "invalid_files_test.rb");
    const plan = path.join(root, "plan.json");
    fs.writeFileSync(source, [
      'Mochi::Test.test("invalid file step") do',
      '  select_files ".input", files: [{ name: "missing bytes" }]',
      "end",
    ].join("\n"));
    const result = spawnSync("ruby", [recorder, testDir, plan], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /invalid_files_test\.rb:2/);
    assert.match(result.stderr, /test file needs exactly one of path or bytes/);
  });
});
