import { spawn, spawnSync, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";

const repoRoot = path.resolve(__dirname, "..", "..");
const installer = path.join(repoRoot, "scripts", "install_dev.rb");
const devUrl = "http://127.0.0.1:27490";

test("installed CLI initializes, builds, tests, and serves Ruby app from another directory", async ({ browser, browserName }) => {
  test.setTimeout(300_000);
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mochi install workflow "));
  const prefix = path.join(tempRoot, "user prefix with spaces");
  const unrelatedCwd = path.join(tempRoot, "unrelated cwd with spaces");
  const projectDir = path.join(unrelatedCwd, "ruby app with spaces");
  const bundleDir = path.join(projectDir, "build");
  const launcher = path.join(prefix, "bin", "mochi");
  fs.mkdirSync(unrelatedCwd, { recursive: true });

  const env = { ...process.env, MOCHI_INSTALL_PREFIX: prefix };
  const run = (args: string[]) => spawnSync(launcher, args, {
    cwd: unrelatedCwd,
    env,
    encoding: "utf8",
    timeout: 240_000,
  });

  let devServer: ReturnType<typeof spawn> | null = null;
  let page: Awaited<ReturnType<typeof browser.newPage>> | null = null;
  try {
    execFileSync("ruby", [installer, "install"], { cwd: unrelatedCwd, env, stdio: "pipe" });
    const help = run(["--help"]);
    expect(help.status, help.stderr).toBe(0);
    expect(help.stdout).toContain("Usage: mochi");

    const initialized = run(["--initialize=ruby app with spaces"]);
    expect(initialized.status, initialized.stderr + initialized.stdout).toBe(0);
    expect(fs.existsSync(path.join(projectDir, "lib", "MyCounter.rb"))).toBe(true);
    expect(fs.existsSync(path.join(projectDir, "test", "counter_test.rb"))).toBe(true);

    const build = run(["-i", projectDir, "-o", bundleDir]);
    expect(build.status, build.stderr + build.stdout).toBe(0);
    expect(fs.existsSync(path.join(bundleDir, "mochi-manifest.json"))).toBe(true);

    const behavior = run(["test", "-i", projectDir, `--browsers=${browserName}`]);
    expect(behavior.status, behavior.stderr + behavior.stdout).toBe(0);
    expect(behavior.stdout).toContain("counter increments");

    if (browserName === "chromium") {
      const config = path.join(projectDir, "dev_server_config.json");
      devServer = spawn(launcher, ["dev", `--config=${config}`, `--root=${projectDir}`], {
        cwd: unrelatedCwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let serverOutput = "";
      devServer.stdout?.on("data", (chunk: Buffer) => { serverOutput += chunk.toString(); });
      devServer.stderr?.on("data", (chunk: Buffer) => { serverOutput += chunk.toString(); });
      const startedAt = Date.now();
      while (!serverOutput.includes("Mochi Dev Server listening") && Date.now() - startedAt < 15_000) {
        if (devServer.exitCode !== null) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      expect(serverOutput, `dev server did not start: ${serverOutput}`).toContain("Mochi Dev Server listening");

      page = await browser.newPage();
      const requests: string[] = [];
      page.on("request", (request) => requests.push(new URL(request.url()).pathname));
      await page.goto(`${devUrl}/deep/entry`);
      const counter = page.locator("my-counter");
      await expect(counter.locator("h1")).toHaveText("Count: 0");
      await counter.getByRole("button", { name: "Increment" }).click();
      await expect(counter.locator("h1")).toHaveText("Count: 1");
      expect(requests).toContain("/build/mochi-loader.js");
      expect(requests).toContain("/build/mochi-manifest.json");
      expect(requests.some((request) => request.startsWith("/build/") && request.endsWith(".chi"))).toBe(true);
    }
  } finally {
    if (page) await page.close();
    if (devServer && devServer.exitCode === null) {
      devServer.kill("SIGTERM");
      await new Promise<void>((resolve) => {
        devServer?.once("exit", () => resolve());
        setTimeout(resolve, 2_000);
      });
    }
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
