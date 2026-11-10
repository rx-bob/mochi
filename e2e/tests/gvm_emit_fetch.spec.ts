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

function writeProject(): void {
  projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-emit-fetch-"));
  bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "EmitSource.rb"), `
class EmitSource
  @tag_name = "emit-source"

  def html
    %Q{<button class="fire" onclick="{fire}">Fire</button>}
  end

  def fire
    Mochi.emit("ping")
    Mochi.emit("select", id: "tr_9f2a")
    Mochi.emit("targeted", id: "tr_7", target: "emit-listener")
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "EmitListener.rb"), `
class EmitListener
  @tag_name = "emit-listener"
  @hits
  @selected
  @targeted

  def initialize
    @hits = 0
    @selected = "none"
    @targeted = "none"
  end

  def html
    %Q{
      <p class="hits">{@hits}</p>
      <p class="selected">{@selected}</p>
      <p class="targeted">{@targeted}</p>
    }
  end

  def ping
    @hits = @hits + 1
  end

  def select(payload)
    @selected = payload[:id]
  end

  def targeted(payload)
    @targeted = payload[:id]
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "OtherListener.rb"), `
class OtherListener
  @tag_name = "other-listener"
  @targeted

  def initialize
    @targeted = "none"
  end

  def html
    %Q{<p class="targeted">{@targeted}</p>}
  end

  def targeted(payload)
    @targeted = "wrong"
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "FetchProbe.rb"), `
class FetchProbe
  @tag_name = "fetch-probe"
  @status
  @ok
  @error
  @row

  def initialize
    @status = 0
    @ok = false
    @error = "none"
    @row = "none"
  end

  def html
    %Q{
      <button class="load" onclick="{load}">Load</button>
      <button class="fail" onclick="{fail}">Fail</button>
      <p class="status">{@status}</p>
      <p class="ok">{@ok}</p>
      <p class="row">{@row}</p>
      <p class="error">{@error}</p>
    }
  end

  def load
    Mochi.fetch("/api/logs", :on_logs)
  end

  def fail
    Mochi.fetch("/api/fail", :on_logs)
  end

  def on_logs(res)
    @status = res[:status]
    @ok = res[:ok]
    if res[:error]
      @error = res[:error]
    else
      @error = "none"
    end
    if res[:data]
      @row = res[:data][:rows][0]
    else
      @row = "none"
    end
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Mochi action and fetch smoke</title>
    <script src="mochi-loader.js"></script>
  </head>
  <body>
    <emit-source></emit-source>
    <emit-listener></emit-listener>
    <other-listener></other-listener>
    <fetch-probe></fetch-probe>
  </body>
</html>
`);
}

function startBundleServer(): Promise<void> {
  server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
    if (requestPath === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    if (requestPath === "/api/logs") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"rows":[1,2]}');
      return;
    }
    if (requestPath === "/api/fail") {
      response.writeHead(500, { "content-type": "text/plain" });
      response.end("boom");
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
  writeProject();
  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });
  await startBundleServer();
});

test.afterAll(async () => {
  if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  if (projectDir) fs.rmSync(projectDir, { recursive: true, force: true });
});

test("Mochi.emit delivers plain and Hash payloads and filters target tags", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));

  await page.goto(`${baseURL}/index.html`);
  await page.locator("emit-source").locator("button.fire").click();

  const listener = page.locator("emit-listener");
  await expect(listener.locator("p.hits")).toHaveText("1");
  await expect(listener.locator("p.selected")).toHaveText("tr_9f2a");
  await expect(listener.locator("p.targeted")).toHaveText("tr_7");
  await expect(page.locator("other-listener").locator("p.targeted")).toHaveText("none");
  expect(errors).toEqual([]);
});

test("Mochi.fetch auto-resolves the component and flushes the callback DOM update", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));

  await page.goto(`${baseURL}/index.html`);
  const probe = page.locator("fetch-probe");
  await probe.locator("button.load").click();

  await expect(probe.locator("p.status")).toHaveText("200");
  await expect(probe.locator("p.ok")).toHaveText("true");
  await expect(probe.locator("p.row")).toHaveText("1");
  await expect(probe.locator("p.error")).toHaveText("none");

  await probe.locator("button.fail").click();
  await expect(probe.locator("p.status")).toHaveText("500");
  await expect(probe.locator("p.ok")).toHaveText("false");
  await expect(probe.locator("p.row")).toHaveText("none");
  await expect(probe.locator("p.error")).toContainText("HTTP 500");
  expect(errors).toEqual([]);
});
