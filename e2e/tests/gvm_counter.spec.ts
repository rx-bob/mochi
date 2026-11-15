import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";
import { setupConsoleLogging } from "./test_utils";

test.describe.configure({ mode: "serial" });

const repoRoot = path.resolve(__dirname, "..", "..");
const compilerBinary = path.join(repoRoot, "compiler", "mochi");
const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
};

let server: http.Server;
let baseURL = "";
let projectDir = "";
let bundleDir = "";
let workspaceDir = "";

function fixtureProject(): string {
  const motestproj = path.join(repoRoot, "e2e", "fixtures", "gvm_counter");
  const injectionMarker = path.join(workspaceDir, "shell-injection-marker");
  const dir = path.join(workspaceDir, `project with spaces;$(touch ${injectionMarker})`);
  fs.cpSync(motestproj, dir, { recursive: true });
  fs.rmSync(path.join(dir, "build"), { recursive: true, force: true });
  fs.rmSync(path.join(dir, "dist"), { recursive: true, force: true });
  return dir;
}

function compileAsync(output: string, cwd: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(compilerBinary, ["-i", projectDir, "-o", output], { cwd });
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`compiler exited ${code}: ${stderr}`)));
  });
}

function assertBundleOutput(): void {
  const required = [
    "mochi-gvm.wasm",
    "mochi-gvm.js",
    "mochi-loader.js",
    "mochi-manifest.json",
    "index.html",
    path.join("components", "my-counter.chi"),
    path.join("components", "my-counter.json"),
  ];
  required.forEach((file) => {
    expect(fs.existsSync(path.join(bundleDir, file)), `missing ${file}`).toBe(true);
  });

  expect(fs.existsSync(path.join(bundleDir, "bundle.js"))).toBe(false);
  const componentFiles = fs.readdirSync(path.join(bundleDir, "components"));
  expect(componentFiles.filter((file) => file.endsWith(".js"))).toEqual([]);

  const manifest = JSON.parse(fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"));
  expect(manifest.wasm_file).toBe("mochi-gvm.wasm");
  expect(manifest.js_file).toBe("mochi-gvm.js");
  expect(manifest.loader_file).toBe("mochi-loader.js");
  expect(manifest.schema_version).toBe(3);
  expect(manifest.format_host).toBeUndefined();
  expect(manifest.capabilities).toBeUndefined();
  expect(Object.keys(manifest.packages)).not.toContain("capability:formatting");
  expect(
    Object.keys(manifest.packages).some((id) => id.startsWith("capability:")),
  ).toBe(false);
  expect(fs.existsSync(path.join(bundleDir, "mochi-format.js"))).toBe(false);
  expect(fs.existsSync(path.join(bundleDir, "mochi-fetch.js"))).toBe(false);
  expect(manifest.components.map((component: { tag_name: string }) => component.tag_name)).toContain("my-counter");
  expect(manifest.components.every((component: { descriptor?: string }) =>
    typeof component.descriptor === "string")).toBe(true);
  expect(manifest.components[0].html_template).toBeUndefined();

  for (const [id, descriptor] of Object.entries(manifest.packages) as Array<[string, any]>) {
    if (descriptor.source?.file) {
      expect(path.isAbsolute(descriptor.source.file), `${id} source path is absolute`).toBe(false);
      expect(descriptor.source.file).not.toContain(workspaceDir);
      expect(descriptor.source.file).not.toContain(projectDir);
    }
  }
  for (const component of manifest.components as Array<{ descriptor: string }>) {
    const descriptor = JSON.parse(fs.readFileSync(path.join(bundleDir, component.descriptor), "utf8"));
    expect(descriptor.source_file).toBeUndefined();
    if (descriptor.source?.file) {
      expect(path.isAbsolute(descriptor.source.file), "component source path is absolute").toBe(false);
      expect(descriptor.source.file).not.toContain(workspaceDir);
      expect(descriptor.source.file).not.toContain(projectDir);
    }
  }
}

function startBundleServer(): Promise<void> {
  server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
    if (requestPath === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    const relative = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
    const filePath = path.resolve(bundleDir, relative);
    if (filePath !== bundleDir && !filePath.startsWith(bundleDir + path.sep)) {
      response.writeHead(403);
      response.end();
      return;
    }
    fs.readFile(filePath, (error, data) => {
      if (error) {
        response.writeHead(404);
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": CONTENT_TYPES[path.extname(filePath)] || "application/octet-stream",
      });
      response.end(data);
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("bundle server did not bind a port");
      baseURL = `http://127.0.0.1:${address.port}`;
      resolve();
    });
  });
}

test.beforeAll(async () => {
  expect(fs.existsSync(compilerBinary), "compiler/mochi is missing; build the compiler first").toBe(true);
  workspaceDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-e2e-"));
  projectDir = fixtureProject();
  bundleDir = path.join(workspaceDir, "bundle");
  const buildCwd = path.join(workspaceDir, "cwd");
  fs.mkdirSync(buildCwd);
  fs.mkdirSync(path.join(buildCwd, "build"));
  fs.writeFileSync(path.join(buildCwd, "build", "sentinel.txt"), "user-owned");

  const started = process.hrtime.bigint();
  const buildOutput = execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: buildCwd,
    encoding: "utf8",
    stdio: "pipe",
  });
  const wallMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  const timing = /Total build took (\d+)ms/.exec(buildOutput);
  expect(timing, `build output missing timing:\n${buildOutput}`).not.toBeNull();
  const buildMs = Number(timing![1]);

  expect(buildMs, `mochi build took ${buildMs}ms (wall ${wallMs.toFixed(1)}ms)`).toBeLessThan(1000);
  expect(buildOutput).not.toMatch(/Processing .*\.rb|ClassName:'/);
  expect(fs.existsSync(path.join(buildCwd, "mochi_build.pftrace"))).toBe(false);

  const traceOutput = execFileSync(compilerBinary, ["-i", projectDir, "-o", path.join(workspaceDir, "trace-bundle")], {
    cwd: buildCwd,
    encoding: "utf8",
    stdio: "pipe",
    env: { ...process.env, MOCHI_BUILD_TRACE: "1" },
  });
  expect(traceOutput).toContain("Trace saved to mochi_build.pftrace");
  expect(fs.existsSync(path.join(buildCwd, "mochi_build.pftrace"))).toBe(true);
  expect(fs.readFileSync(path.join(buildCwd, "build", "sentinel.txt"), "utf8")).toBe("user-owned");
  expect(fs.existsSync(path.join(workspaceDir, "shell-injection-marker"))).toBe(false);
  assertBundleOutput();
  await startBundleServer();
});

test("rejects unsafe output aliases and runs simultaneous builds in isolated workspaces", async () => {
  expect(() => execFileSync(compilerBinary, ["-i", projectDir, "-o", projectDir], { encoding: "utf8" })).toThrow();
  expect(fs.existsSync(path.join(projectDir, "lib", "MyCounter.rb"))).toBe(true);

  expect(() => execFileSync(compilerBinary, ["-i", projectDir, "-o", workspaceDir], { encoding: "utf8" })).toThrow();

  const outputAlias = path.join(workspaceDir, "output-alias");
  fs.symlinkSync(projectDir, outputAlias, "dir");
  expect(() => execFileSync(compilerBinary, ["-i", projectDir, "-o", outputAlias], { encoding: "utf8" })).toThrow();

  const symlinkProject = path.join(workspaceDir, "project-with-symlink");
  fs.cpSync(projectDir, symlinkProject, { recursive: true });
  fs.symlinkSync(path.join(projectDir, "lib", "MyCounter.rb"), path.join(symlinkProject, "lib", "external.rb"));
  const preservedOutput = path.join(workspaceDir, "preserve-on-symlink-error");
  fs.mkdirSync(path.join(preservedOutput, "components"), { recursive: true });
  fs.writeFileSync(path.join(preservedOutput, "sentinel.txt"), "still here");
  fs.writeFileSync(path.join(preservedOutput, "components", "old.chi"), "old output");
  expect(() => execFileSync(compilerBinary, ["-i", symlinkProject, "-o", preservedOutput], { encoding: "utf8" })).toThrow();
  expect(fs.readFileSync(path.join(preservedOutput, "sentinel.txt"), "utf8")).toBe("still here");
  expect(fs.readFileSync(path.join(preservedOutput, "components", "old.chi"), "utf8")).toBe("old output");

  const outputs = [path.join(workspaceDir, "parallel-one"), path.join(workspaceDir, "parallel-two")];
  await Promise.all(outputs.map((output) => compileAsync(output, path.join(workspaceDir, "cwd"))));
  for (const output of outputs) {
    expect(fs.existsSync(path.join(output, "mochi-manifest.json"))).toBe(true);
    expect(fs.existsSync(path.join(output, "components", "my-counter.chi"))).toBe(true);
  }
  expect(fs.readFileSync(path.join(outputs[0], "mochi-manifest.json"), "utf8"))
    .toBe(fs.readFileSync(path.join(outputs[1], "mochi-manifest.json"), "utf8"));
  expect(fs.readFileSync(path.join(outputs[0], "components", "my-counter.chi")))
    .toEqual(fs.readFileSync(path.join(outputs[1], "components", "my-counter.chi")));
  expect(fs.readFileSync(path.join(workspaceDir, "cwd", "build", "sentinel.txt"), "utf8")).toBe("user-owned");
});

test.afterAll(async () => {
  if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  if (workspaceDir) fs.rmSync(workspaceDir, { recursive: true, force: true });
});

test("mounts my-counter, clicks increment/decrement, and preserves button nodes", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("response", (response) => {
    if (response.status() >= 400 && !response.url().endsWith("/favicon.ico")) {
      errors.push(`HTTP ${response.status()} ${response.url()}`);
    }
  });

  await page.goto(`${baseURL}/index.html`);

  const counter = page.locator("my-counter");
  const heading = counter.locator("h1");
  const state = counter.locator("p.state");
  const mode = counter.locator("p.mode");
  const increment = counter.locator("button").nth(0);
  const decrement = counter.locator("button").nth(1);

  await expect(heading).toHaveText("Count: 0");
  expect(requested.filter((url) => url.endsWith("/mochi-format.js"))).toHaveLength(0);
  expect(requested.filter((url) => /\/components\/ruby-[0-9a-f]+\.chi$/.test(url))).toHaveLength(0);
  await expect(state).toHaveClass(/\bneutral\b/);
  await expect(mode).not.toHaveClass(/\bactive\b/);
  await expect(increment).toHaveText("Increment");
  await expect(decrement).toHaveText("Decrement");
  await expect(increment).toHaveCSS("background-color", "rgb(165, 50, 105)");

  await page.evaluate(() => {
    const element = document.querySelector("my-counter") as HTMLElement & { shadowRoot: ShadowRoot };
    (window as any).__gvmButtons = Array.from(element.shadowRoot.querySelectorAll("button"));
    (window as any).__gvmHeading = element.shadowRoot.querySelector("h1");
  });

  await increment.click();
  await increment.click();
  await increment.click();
  await decrement.click();

  await expect(heading).toHaveText("Count: 2");
  await expect(state).toHaveClass(/\bpositive\b/);
  await expect(mode).toHaveClass(/\bactive\b/);

  const identity = await page.evaluate(() => {
    const element = document.querySelector("my-counter") as HTMLElement & { shadowRoot: ShadowRoot };
    const buttons = Array.from(element.shadowRoot.querySelectorAll("button"));
    const previous = (window as any).__gvmButtons as HTMLElement[];
    return {
      buttonsSame: buttons.length === previous.length && buttons.every((button, index) => button === previous[index]),
      headingSame: element.shadowRoot.querySelector("h1") === (window as any).__gvmHeading,
    };
  });

  expect(identity.buttonsSame).toBe(true);
  expect(identity.headingSame).toBe(true);
  expect(errors).toEqual([]);
});
