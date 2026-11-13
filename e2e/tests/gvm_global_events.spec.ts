import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";
import { setupConsoleLogging } from "./test_utils";

const repoRoot = path.resolve(__dirname, "..", "..");
const compilerBinary = path.join(repoRoot, "compiler", "mochi");
const contentTypes: Record<string, string> = {
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

function writeProject(): void {
  projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-global-events-"));
  bundleDir = path.join(projectDir, "bundle");
  const lib = path.join(projectDir, "lib");
  fs.mkdirSync(lib, { recursive: true });

  fs.writeFileSync(path.join(lib, "EventPublisher.rb"), `
class EventPublisher
  @tag_name = "event-publisher"
  @publishes

  def initialize
    @publishes = 0
  end

  def html
    %Q{<button onclick="{open_profile}">Publish</button><p class="publishes">{@publishes}</p>}
  end

  def open_profile
    @publishes = @publishes + 1
    Mochi.emit("open_profile", id: 9007199254740993, active: false, empty: nil)
  end
end
`);

  fs.writeFileSync(path.join(lib, "EventSubscriber.rb"), `
class EventSubscriber
  @tag_name = "event-subscriber"
  @deliveries
  @result

  def initialize
    @deliveries = 0
    @result = "none"
  end

  def mounted
    Mochi.subscribe("open_profile", :open_profile)
  end

  def html
    %Q{<button class="stop" onclick="{stop}">Stop</button><p class="deliveries">{@deliveries}</p><p class="result">{@result}</p>}
  end

  def stop
    Mochi.unsubscribe("open_profile", :open_profile)
  end

  def open_profile(payload)
    @deliveries = @deliveries + 1
    @result = payload[:id].to_s + ":" + payload[:active].to_s + ":" + payload[:empty].to_s
  end
end
`);

  fs.writeFileSync(path.join(lib, "UnregisteredListener.rb"), `
class UnregisteredListener
  @tag_name = "unregistered-listener"
  @calls

  def initialize
    @calls = 0
  end

  def html
    %Q{<p class="calls">{@calls}</p>}
  end

  def open_profile(payload)
    @calls = @calls + 1
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "index.html"), `
<!doctype html>
<html><head><meta charset="utf-8"><script src="mochi-loader.js"></script></head>
<body>
  <event-publisher id="publisher"></event-publisher>
  <event-subscriber id="first"></event-subscriber>
  <event-subscriber id="second"></event-subscriber>
  <unregistered-listener id="unregistered"></unregistered-listener>
</body></html>
`);
}

function startBundleServer(): Promise<void> {
  const types = contentTypes;
  server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
    const relative = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
    const filePath = path.resolve(bundleDir, relative);
    if (filePath !== bundleDir && !filePath.startsWith(bundleDir + path.sep)) {
      response.writeHead(403).end();
      return;
    }
    fs.readFile(filePath, (error, data) => {
      if (error) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, {
        "content-type": types[path.extname(filePath)] || "application/octet-stream",
      });
      response.end(data);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("server did not bind a port");
      baseURL = `http://127.0.0.1:${address.port}`;
      resolve();
    });
  });
}

test.beforeAll(async () => {
  writeProject();
  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    stdio: "pipe",
  });
  await startBundleServer();
});

test.afterAll(async () => {
  if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  if (projectDir) fs.rmSync(projectDir, { recursive: true, force: true });
});

test("Ruby global events reach explicit live subscribers with exact payload values", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`${baseURL}/index.html`);

  const publisher = page.locator("#publisher");
  const first = page.locator("#first");
  const second = page.locator("#second");
  const unregistered = page.locator("#unregistered");
  await publisher.locator("button").click();
  await expect(publisher.locator(".publishes")).toHaveText("1");
  await expect(first.locator(".deliveries")).toHaveText("1");
  await expect(second.locator(".deliveries")).toHaveText("1");
  await expect(first.locator(".result")).toHaveText("9007199254740993:false:");
  await expect(second.locator(".result")).toHaveText("9007199254740993:false:");
  await expect(unregistered.locator(".calls")).toHaveText("0");

  await first.locator("button.stop").click();
  await publisher.locator("button").click();
  await expect(publisher.locator(".publishes")).toHaveText("2");
  await expect(first.locator(".deliveries")).toHaveText("1");
  await expect(second.locator(".deliveries")).toHaveText("2");
  await expect(unregistered.locator(".calls")).toHaveText("0");

  await page.evaluate(() => document.querySelector("#second")?.remove());
  await publisher.locator("button").click();
  await expect(publisher.locator(".publishes")).toHaveText("3");
  await expect(first.locator(".deliveries")).toHaveText("1");
  await expect(unregistered.locator(".calls")).toHaveText("0");
  expect(errors).toEqual([]);
});
