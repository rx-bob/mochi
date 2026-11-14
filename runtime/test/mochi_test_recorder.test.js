const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const recorder = path.resolve(__dirname, "mochi_test_recorder.rb");

test("Ruby recorder captures download byte expectations and authored locations", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "export_test.rb"), plan = path.join(root, "plan.json");
    fs.writeFileSync(source, 'Mochi::Test.test("export") do\n  download ".export"\n  assert_download filename: "résumé.bin", bytes: [0, 128, 255]\nend\n');
    const result = spawnSync("ruby", [recorder, testDir, plan], {encoding:"utf8"});
    assert.equal(result.status, 0, result.stderr);
    const steps = JSON.parse(fs.readFileSync(plan, "utf8")).tests[0].steps;
    assert.equal(steps[0].operation, "download");
    assert.equal(steps[0].selector, ".export");
    assert.equal(steps[1].operation, "assert_download");
    assert.equal(steps[1].filename, "résumé.bin");
    assert.deepEqual(steps[1].bytes, [0,128,255]);
    assert.equal(steps[1].ruby_file, source);
    assert.equal(steps[1].line, 3);
  });
});

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
      assert.equal(step.ruby_file, source);
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

test("Ruby recorder selects one test file and preserves scenario and step locations", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "inspector_test.rb");
    const plan = path.join(root, "plan.json");
    fs.writeFileSync(source, 'Mochi::Test.test("selected") do\n  mount "inspector-root"\nend\n');
    fs.writeFileSync(path.join(testDir, "unselected_test.rb"), 'raise "must not load unselected tests"');
    const result = spawnSync("ruby", [recorder, testDir, plan, "inspector_test.rb"], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const tests = JSON.parse(fs.readFileSync(plan, "utf8")).tests;
    assert.equal(tests.length, 1);
    assert.equal(tests[0].name, "selected");
    assert.equal(tests[0].ruby_file, source);
    assert.equal(tests[0].line, 1);
    assert.equal(tests[0].steps[0].line, 2);
  });
});

test("Ruby recorder rejects unknown or outside test selections", () => {
  withTestProject((root, testDir) => {
    const plan = path.join(root, "plan.json");
    fs.writeFileSync(path.join(root, "outside_test.rb"), 'raise "must not load outside tests"');
    for (const selection of ["", "missing_test.rb", "../outside_test.rb"]) {
      const result = spawnSync("ruby", [recorder, testDir, plan, selection], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /no Ruby test file/);
      assert.equal(fs.existsSync(plan), false);
    }
  });
});

test("Ruby recorder requires an explicit nonempty error matcher", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "errors_test.rb");
    for (const matcher of ['nil', '""', '"  "']) {
      fs.writeFileSync(source, `Mochi::Test.test("bad matcher") do\n  expect_error ${matcher}\nend\n`);
      const result = spawnSync("ruby", [recorder, testDir, path.join(root, "plan.json")], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /expect_error requires a non-empty message/);
      assert.match(result.stderr, /errors_test\.rb:2/);
    }
  });
});

test("Ruby recorder preserves keyboard/focus steps and authored locations", () => {
  withTestProject((root, testDir) => {
    const source = path.join(testDir, "focus_test.rb");
    const plan = path.join(root, "plan.json");
    fs.writeFileSync(source, 'Mochi::Test.test("keyboard") do\n  focus "field-editor >>> .draft"\n  press "Tab"\n  assert_focused ".save"\nend\n');
    const result = spawnSync("ruby", [recorder, testDir, plan], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const steps = JSON.parse(fs.readFileSync(plan, "utf8")).tests[0].steps;
    assert.deepEqual(steps.map(step => [step.operation, step.selector || step.key, step.line]), [
      ["focus", "field-editor >>> .draft", 2], ["press", "Tab", 3], ["assert_focused", ".save", 4],
    ]);
    assert.ok(steps.every(step => step.ruby_file === source));
  });
});
