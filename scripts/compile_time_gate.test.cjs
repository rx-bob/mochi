const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const repoRoot = path.resolve(__dirname, "..");
const gate = path.join(__dirname, "compile_time_gate.cjs");

test("normal compile-time gate rejects a deliberately delayed compiler", () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-compile-gate-delay-"));
  const delayedCompiler = path.join(workspace, "delayed-compiler.cjs");
  fs.writeFileSync(delayedCompiler, [
    "#!/usr/bin/env node",
    "const delay = new Int32Array(new SharedArrayBuffer(4));",
    "Atomics.wait(delay, 0, 0, 1100);",
    "process.exit(0);",
    "",
  ].join("\n"), { mode: 0o755 });

  try {
    const result = spawnSync(process.execPath, [
      gate,
      "--compiler", delayedCompiler,
      "--fixture", "minimal",
      "--scenario", "cold",
      "--runs", "1",
    ], { cwd: repoRoot, encoding: "utf8", timeout: 10000 });
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /minimal\/cold: .*limit < 1000 ms/);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});
