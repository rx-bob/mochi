const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

process.env.MOCHI_TEST_RUNNER_LIBRARY = "1";
const { syntheticFiles } = require("../../e2e/mochi_test_runner.cjs");
delete process.env.MOCHI_TEST_RUNNER_LIBRARY;

test("browser runner resolves Ruby test file paths and preserves inline bytes", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-runner-files-"));
  const source = path.join(root, "files_test.rb");
  const fixture = path.join(root, "sample.bin");
  fs.writeFileSync(fixture, Buffer.from([0, 128, 255]));
  try {
    const files = syntheticFiles({
      ruby_file: source,
      line: 7,
      files: [
        { path: "sample.bin", type: "application/octet-stream" },
        { name: "inline.bin", bytes: [0, 255] },
      ],
    });
    assert.equal(files[0].name, "sample.bin");
    assert.deepEqual([...files[0].bytes], [0, 128, 255]);
    assert.deepEqual([...files[1].bytes], [0, 255]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("browser runner reports invalid test paths at the calling Ruby line", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-runner-bad-file-"));
  try {
    assert.throws(
      () => syntheticFiles({ ruby_file: path.join(root, "files_test.rb"), line: 19, files: [{ path: "missing.bin" }] }),
      /files_test\.rb:19: cannot read test file 'missing\.bin'/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
