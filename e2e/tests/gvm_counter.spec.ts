import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";
import { setupConsoleLogging } from "./test_utils";

test.use({ channel: "chrome" });
test.describe.configure({ mode: "serial" });

const repoRoot = path.resolve(__dirname, "..", "..");
const bundleDir = path.join(repoRoot, "build_gvm");
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
let temporaryProjectDir = "";

function fixtureProject(): string {
  const motestproj = path.join(repoRoot, "compiler", "motestproj");
  if (fs.existsSync(path.join(motestproj, "lib", "MyCounter.rb"))) return motestproj;

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-e2e-"));
  fs.mkdirSync(path.join(dir, "lib"), { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, "fragments", "builtins", "my_counter.rb"),
    path.join(dir, "lib", "MyCounter.rb")
  );
  fs.writeFileSync(
    path.join(dir, "index.html"),
    [
      "<!doctype html>",
      '<html><head><meta charset="utf-8">',
      '<script src="mochi-loader.js"></script>',
      "</head><body><my-counter></my-counter></body></html>",
    ].join("\n")
  );
  temporaryProjectDir = dir;
  return dir;
}

function assertBundleOutput(): void {
  const required = [
    "mochi-gvm.wasm",
    "mochi-gvm.js",
    "mochi-loader.js",
    "mochi-manifest.json",
    "index.html",
    path.join("components", "my-counter.chi"),
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
  expect(manifest.components.map((component: { tag_name: string }) => component.tag_name)).toContain("my-counter");
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
  projectDir = fixtureProject();
  fs.rmSync(bundleDir, { recursive: true, force: true });

  const started = process.hrtime.bigint();
  const buildOutput = execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });
  const wallMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  const timing = /Total build took (\d+)ms/.exec(buildOutput);
  expect(timing, `build output missing timing:\n${buildOutput}`).not.toBeNull();
  const buildMs = Number(timing![1]);

  expect(buildMs, `mochi build took ${buildMs}ms (wall ${wallMs.toFixed(1)}ms)`).toBeLessThan(200);
  assertBundleOutput();
  await startBundleServer();
});

test.afterAll(async () => {
  if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  if (temporaryProjectDir) fs.rmSync(temporaryProjectDir, { recursive: true, force: true });
});

test("mounts my-counter, clicks increment/decrement, and preserves button nodes", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("response", (response) => {
    if (response.status() >= 400 && !response.url().endsWith("/favicon.ico")) {
      errors.push(`HTTP ${response.status()} ${response.url()}`);
    }
  });

  await page.goto(`${baseURL}/index.html`);

  const counter = page.locator("my-counter");
  const heading = counter.locator("h1");
  const increment = counter.locator("button").nth(0);
  const decrement = counter.locator("button").nth(1);

  await expect(heading).toHaveText("Count: 0");
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
