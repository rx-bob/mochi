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

const { EventEmitter } = require("node:events");
const { collectDiagnostics, assertDiagnostics } = require("../../e2e/mochi_test_runner.cjs");

function diagnosticPage() {
  const page = new EventEmitter();
  page.runtimeErrors = [];
  page.evaluate = async () => page.runtimeErrors.splice(0);
  return page;
}

function consoleError(text, error) {
  return { type: () => "error", text: () => text,
    args: () => error ? [{ evaluate: async fn => fn(error) }] : [] };
}

test("unexpected initial-render console errors fail at the authored Ruby line", async () => {
  const page = diagnosticPage();
  const drain = collectDiagnostics(page);
  page.emit("console", consoleError("invalid initial SVG path"));
  const diagnostics = await drain();
  assert.throws(() => assertDiagnostics(diagnostics, "inspector_test.rb:12"),
    /inspector_test\.rb:12: console error: invalid initial SVG path/);
});

test("matching browser diagnostics are consumed and do not poison later steps", async () => {
  const page = diagnosticPage();
  const drain = collectDiagnostics(page);
  page.emit("console", consoleError("[mochi] mount failed Error", new Error("expected mount failure")));
  page.emit("pageerror", new Error("expected mount failure"));
  page.runtimeErrors.push({ message: "expected mount failure", source: "lib/Root.rb:7" });
  const diagnostics = await drain();
  assert.equal(diagnostics.length, 3);
  assertDiagnostics(diagnostics, "test.rb:3", "expected mount failure", new Error("expected mount failure"));
  assertDiagnostics(await drain(), "test.rb:4");
  page.emit("console", consoleError("later unexpected error"));
  const later = await drain();
  assert.throws(() => assertDiagnostics(later, "test.rb:5"), /later unexpected error/);
});

test("negative steps reject unrelated errors even after matching runtime errors", async () => {
  const page = diagnosticPage();
  const drain = collectDiagnostics(page);
  page.runtimeErrors.push({ message: "expected failure" }, { message: "unrelated failure", source: "lib/Root.rb:9" });
  const diagnostics = await drain();
  assert.throws(() => assertDiagnostics(diagnostics, "test.rb:8", "expected failure"),
    /test\.rb:8: Mochi runtime error \(lib\/Root\.rb:9\): unrelated failure/);
  assert.throws(() => assertDiagnostics([], "test.rb:9", "expected failure"), /but no error occurred/);
  assert.throws(() => assertDiagnostics([], "test.rb:10", "expected failure", new Error("expected failure")),
    /test\.rb:10: expected failure/);
});

test("runner labels setup failures and closes the page even before navigation", async () => {
  const { runCase } = require("../../e2e/mochi_test_runner.cjs");
  const page = diagnosticPage();
  let closed = false;
  page.addInitScript = async () => { throw new Error("controlled setup failure"); };
  page.close = async () => { closed = true; };
  await assert.rejects(runCase({ newPage: async () => page }, "chromium", "http://127.0.0.1", {
    name: "setup", ruby_file: "scenario_test.rb", line: 6, steps: [],
  }), /scenario_test\.rb:6: controlled setup failure/);
  assert.equal(closed, true);
});

test("driver errors keep one authored location rather than repeated prefixes", () => {
  const error = new Error("test.rb:10: selector missing");
  assert.throws(() => assertDiagnostics([], "test.rb:10", null, error), actual => actual === error);
});
