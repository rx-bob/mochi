import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";

const repoRoot = path.resolve(__dirname, "..", "..");
const installer = path.join(repoRoot, "scripts", "install_dev.rb");

test("installed mochi builds and runs Ruby behavior tests outside the checkout", async ({ browserName }) => {
  test.setTimeout(240_000);
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mochi install cli "));
  const prefix = path.join(tempRoot, "user prefix with spaces");
  const unrelatedCwd = path.join(tempRoot, "unrelated cwd with spaces");
  const projectDir = path.join(tempRoot, "ruby project with spaces");
  const bundleDir = path.join(tempRoot, "build output with spaces");
  const launcher = path.join(prefix, "bin", "mochi");
  fs.mkdirSync(unrelatedCwd, { recursive: true });
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "test"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "InstallCounter.rb"), `
class InstallCounter
  @tag_name = "install-counter"
  @count

  def initialize
    @count = 0
  end

  def html
    %Q{<button onclick="{increment}">Add</button><p class="value">Count: {@count}</p>}
  end

  def increment
    @count = @count + 1
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "test", "counter_test.rb"), `
Mochi::Test.test("installed counter increments") do
  mount "install-counter"
  click "button"
  wait_for_settled
  assert_text ".value", "Count: 1"
end
`);

  const env = { ...process.env, MOCHI_INSTALL_PREFIX: prefix };
  const run = (args: string[]) => spawnSync(launcher, args, {
    cwd: unrelatedCwd,
    env,
    encoding: "utf8",
    timeout: 210_000,
  });

  try {
    execFileSync("ruby", [installer, "install"], { cwd: unrelatedCwd, env, stdio: "pipe" });
    const help = run(["--help"]);
    expect(help.status, help.stderr).toBe(0);
    expect(help.stdout).toContain("Usage: mochi");

    const build = run(["-i", projectDir, "-o", bundleDir]);
    expect(build.status, build.stderr + build.stdout).toBe(0);
    expect(fs.existsSync(path.join(bundleDir, "mochi-manifest.json"))).toBe(true);

    const behavior = run(["test", "-i", projectDir, `--browsers=${browserName}`]);
    expect(behavior.status, behavior.stderr + behavior.stdout).toBe(0);
    expect(behavior.stdout).toContain("installed counter increments");
  } finally {
    const remove = spawnSync("ruby", [installer, "remove"], {
      cwd: unrelatedCwd,
      env,
      encoding: "utf8",
      timeout: 30_000,
    });
    if (remove.status !== 0) {
      throw new Error(`could not remove temporary development install: ${remove.stderr}`);
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
