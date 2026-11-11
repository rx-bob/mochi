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
const senchaDistDir = "/Users/bob/repos/sencha/frontend-mochi/dist";

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
  ".woff2": "font/woff2",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

function startStaticServer(rootDir: string): Promise<{ server: http.Server; baseURL: string }> {
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
    if (requestPath === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    const relative = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
    const filePath = path.resolve(rootDir, relative);
    if (filePath !== rootDir && !filePath.startsWith(rootDir + path.sep)) {
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
      if (!address || typeof address === "string") throw new Error("server did not bind a port");
      resolve({ server, baseURL: `http://127.0.0.1:${address.port}` });
    });
  });
}

test("GVM evolved features: prelude helpers, each events/helpers, props, timers, storage, routing, and class toggle", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-evolved-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "MathHelper.rb"), `
class MathHelper
  def self.pct(a, b)
    (a * 100) / b
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "ChildBadge.rb"), `
class ChildBadge
  @tag_name = "child-badge"
  @label

  def initialize
    @label = "unset"
  end

  def html
    %Q{<span class="badge-text">{@label}</span>}
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "FeatureHost.rb"), `
class FeatureHost
  @tag_name = "feature-host"
  @items
  @picked
  @draft
  @active
  @timer_done
  @last_key
  @pct_val

  def initialize
    @items = [
      {"id" => "q1", "status" => "paused"},
      {"id" => "q2", "status" => "running"}
    ]
    @picked = Mochi.storage_get("saved_pick", "none")
    @draft = "hi"
    @active = true
    @timer_done = false
    @last_key = "none"
    @pct_val = MathHelper.pct(16, 20)
  end

  def label_for(item)
    item["status"] == "paused" ? "Resume" : "Pause"
  end

  def html
    %Q{
      <div class="host">
        <p class="literal">{{hello}}</p>
        <p class="pct">{@pct_val}%</p>
        <p class="picked">{@picked}</p>
        <p class="timer">{@timer_done}</p>
        <p class="key">{@last_key}</p>
        <button class="pill {{ on: @active }}" onclick="{flip}">Flip</button>
        <input class="draft" type="text" bind:value="@draft">
        <p class="draft-out">{@draft}</p>
        <child-badge label="synced-prop"></child-badge>
        <div class="list">
          {each @items as it}
            <button class="item-btn" onclick="{pick}">{label_for(it)}</button>
          {end}
        </div>
      </div>
    }
  end

  def pick(e)
    item = e[:item]
    if item
      @picked = "#{item["id"]}:#{e[:index]}"
      Mochi.storage_set("saved_pick", @picked)
    end
  end

  def flip
    @active = !@active
    Mochi.after(50, :mark_timer)
  end

  def mark_timer
    @timer_done = true
  end

  def on_key(ev)
    @last_key = ev[:key]
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <script src="mochi-loader.js"></script>
  </head>
  <body>
    <feature-host></feature-host>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const host = page.locator("feature-host");

    await expect(host.locator("p.literal")).toHaveText("{hello}");
    await expect(host.locator("p.pct")).toHaveText("80%");
    await expect(host.locator("child-badge").locator("span.badge-text")).toHaveText("synced-prop");

    const itemBtns = host.locator("button.item-btn");
    await expect(itemBtns.nth(0)).toHaveText("Resume");
    await expect(itemBtns.nth(1)).toHaveText("Pause");

    await itemBtns.nth(1).click();
    await expect(host.locator("p.picked")).toHaveText("q2:1");

    const pill = host.locator("button.pill");
    await expect(pill).toHaveClass(/pill/);
    await expect(pill).toHaveClass(/on/);
    await pill.click();
    await expect(pill).toHaveClass(/pill/);
    await expect(pill).not.toHaveClass(/\bon\b/);
    await expect(host.locator("p.timer")).toHaveText("true");

    await host.locator("input.draft").fill("updated");
    await expect(host.locator("p.draft-out")).toHaveText("updated");

    await page.keyboard.press("Escape");
    await expect(host.locator("p.key")).toHaveText("Escape");

    // Reload to verify Mochi.storage_get seeded from localStorage
    await page.reload();
    await expect(host.locator("p.picked")).toHaveText("q2:1");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

function screenComponentSource(tagName: string, className: string, bindingCount: number): string {
  const ivars = Array.from({ length: bindingCount }, (_, index) => `  @v${index}`).join("\n");
  const assignments = Array.from(
    { length: bindingCount },
    (_, index) => `    @v${index} = "${tagName}-${index}"`,
  ).join("\n");
  const spans = Array.from(
    { length: bindingCount },
    (_, index) => `        <span class="v v${index}">{@v${index}}</span>`,
  ).join("\n");
  return `class ${className}
  @tag_name = "${tagName}"
${ivars}

  def initialize
${assignments}
  end

  def html
    %Q{
      <div class="screen">
${spans}
      </div>
    }
  end
end
`;
}

test("VM registrations return to the active-screen baseline across 200 round trips", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-lifetime-"));
  const bundleDir = path.join(projectDir, "bundle");
  const bindingCount = 40;
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(
    path.join(projectDir, "lib", "ScreenA.rb"),
    screenComponentSource("screen-a", "ScreenA", bindingCount),
  );
  fs.writeFileSync(
    path.join(projectDir, "lib", "ScreenB.rb"),
    screenComponentSource("screen-b", "ScreenB", bindingCount),
  );
  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <script src="mochi-loader.js"></script>
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    await page.waitForFunction(() => {
      const loader = (window as any).MochiLoader;
      return loader && loader.components.length === 2 &&
        window.customElements.get("screen-a") &&
        window.customElements.get("screen-b");
    });

    const result = await page.evaluate(async () => {
      const root = document.getElementById("root");
      if (!root) throw new Error("missing root");
      const stats = () => (window as any).MochiLoader.debugStats();
      const mount = async (tag: string) => {
        const element = document.createElement(tag);
        root.appendChild(element);
        await (element as any)._mochiReady;
        return element;
      };

      let current = await mount("screen-a");
      const baseline = stats();
      const samples: Array<Record<string, number>> = [];
      let mountCount = 1;
      for (let round = 0; round < 200; round += 1) {
        current.remove();
        const second = await mount("screen-b");
        mountCount += 1;
        samples.push(stats());
        second.remove();
        const first = await mount("screen-a");
        mountCount += 1;
        samples.push(stats());
        current = first;
      }
      current.remove();
      const finalStats = stats();
      const bad = samples.filter((sample) =>
        sample.components !== baseline.components ||
        sample.bindings !== baseline.bindings ||
        sample.elements !== baseline.elements
      );
      return { baseline, finalStats, badCount: bad.length, firstBad: bad[0] || null, mountCount };
    });

    expect(result.baseline.components).toBe(1);
    expect(result.baseline.bindings).toBe(bindingCount);
    expect(result.baseline.elements).toBe(1);
    expect(result.badCount).toBe(0);
    expect(result.finalStats.components).toBe(0);
    expect(result.finalStats.bindings).toBe(0);
    expect(result.finalStats.elements).toBe(0);
    expect(result.finalStats.timers).toBe(0);
    expect(result.finalStats.pendingFetches).toBe(0);
    expect(result.mountCount).toBe(401);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("Sencha frontend-mochi showcase works across all 8 screens with zero errors", async ({ page }) => {
  test.skip(!fs.existsSync(senchaDistDir), "sencha/frontend-mochi/dist not built");
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(senchaDistDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("z-root");
    const topbar = root.locator("top-bar");

    // 1. Home screen & "View all" / "Inspect queues" links
    const home = root.locator("home-screen");
    await expect(home.locator("h1")).toHaveText("Keep the herd moving.");
    await home.locator('button[data-screen="events"]').click();

    // 2. Events screen (navigated from Home "View all")
    const events = root.locator("events-screen");
    await expect(events.locator("h1")).toHaveText("Events");
    await expect(events.locator(".event-row")).toHaveCount(12);
    await events.locator('button[data-level="warn"]').click();
    await expect(events.locator(".event-row")).toHaveCount(1);
    await events.locator(".event-row").first().click();
    await expect(events.locator("aside.detail h2")).toContainText("queue.enqueued");

    // 3. Queues screen & {toggle_label(q)} helper inside {each}
    await topbar.locator('button[data-screen="queues"]').click();
    const queues = root.locator("queues-screen");
    await expect(queues.locator("h1")).toHaveText("Queues");
    const firstToggle = queues.locator('button[data-action="toggle"]').first();
    await expect(firstToggle).toHaveText("Pause");
    await firstToggle.click();
    await expect(firstToggle).toHaveText("Resume");

    // 4. Costs screen dynamic period & harness filtering
    await topbar.locator('button[data-screen="costs"]').click();
    const costs = root.locator("costs-screen");
    await expect(costs.locator(".summary.primary strong")).toHaveText("183k");
    await costs.locator('button[data-period="30"]').click();
    await expect(costs.locator(".summary.primary strong")).toHaveText("549k");
    await costs.locator('button[data-harness="Codex"]').click();
    await expect(costs.locator("tbody tr")).toHaveCount(2);

    // 5. Limits screen
    await topbar.locator('button[data-screen="limits"]').click();
    await expect(root.locator("limits-screen h1")).toHaveText("Usage limits");

    // 6. Logs screen filtering & drawer
    await topbar.locator('button[data-screen="logs"]').click();
    const logs = root.locator("logs-screen");
    await expect(logs.locator(".log-row")).toHaveCount(8);
    await logs.locator('button[data-level="error"]').click();
    await expect(logs.locator(".log-row")).toHaveCount(1);
    await logs.locator(".log-row").first().click();
    await expect(logs.locator("aside.drawer h2")).toHaveText("error");
    await logs.locator('aside.drawer button[data-action="close-drawer"]').click();

    // 7. Canvas screen node inspector & Steward
    await topbar.locator('button[data-screen="canvas"]').click();
    const canvas = root.locator("canvas-screen");
    await canvas.locator('.node[data-node="engineering"]').click();
    await expect(canvas.locator(".inspector h2")).toHaveText("Engineering");

    // 8. Settings screen & localStorage persistence across reload
    await topbar.locator('button[data-screen="settings"]').click();
    const settings = root.locator("settings-screen");
    await expect(settings.locator(".runtime-item.good")).toHaveCount(6);
    await settings.locator('button[data-action="dark"]').click();
    await expect(root.locator(".shell")).toHaveClass(/dark/);

    await page.reload();
    await expect(root.locator(".shell")).toHaveClass(/dark/);
    await expect(root.locator("settings-screen h1")).toHaveText("Settings");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("shared values survive unmount while replaced storage stays bounded", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-reclaim-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "SharedLifetime.rb"), `SHARED = []

class SharedLifetime
  @tag_name = "shared-lifetime"
  @payload
  @count
  @shared

  def initialize
    @payload = "payload-start"
    @count = 0
    @shared = SHARED
  end

  def html
    %Q{
      <div class="shared-lifetime">
        <p class="payload">{@payload}</p>
        <p class="count">{@count}</p>
        <button class="churn" onclick="{churn}">Churn</button>
        <button class="late" onclick="{start_late}">Late</button>
      </div>
    }
  end

  def churn
    SHARED.push("kept")
    i = 0
    even = true
    while i < 1000
      if even
        @payload = "payload-even"
      else
        @payload = "payload-odd"
      end
      even = !even
      i += 1
    end
    @count = i
  end

  def start_late
    Mochi.after(300, :late_callback)
  end

  def late_callback
    @payload = "late-fired"
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "SharedPeer.rb"), `class SharedPeer
  @tag_name = "shared-peer"
  @seen
  @shared

  def initialize
    @seen = 0
    @shared = SHARED
  end

  def html
    %Q{
      <div class="shared-peer">
        <p class="seen">{@seen}</p>
        <button class="sync" onclick="{sync}">Sync</button>
      </div>
    }
  end

  def sync
    @seen = @shared.length
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <script src="mochi-loader.js"></script>
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    await page.waitForFunction(() => {
      const loader = (window as any).MochiLoader;
      return loader && loader.components.length === 2 &&
        window.customElements.get("shared-lifetime") &&
        window.customElements.get("shared-peer");
    });

    const result = await page.evaluate(async () => {
      const root = document.getElementById("root");
      if (!root) throw new Error("missing root");
      const stats = () => (window as any).MochiLoader.debugStats();
      const mount = async (tag: string) => {
        const element = document.createElement(tag);
        root.appendChild(element);
        await (element as any)._mochiReady;
        return element;
      };
      const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

      const owner = await mount("shared-lifetime");
      const peer = await mount("shared-peer");
      const before = stats();
      const shadow = (element: Element) => element.shadowRoot as ShadowRoot;
      shadow(owner).querySelector<HTMLButtonElement>(".churn")!.click();
      await wait(150);
      const payload = shadow(owner).querySelector(".payload")!.textContent;
      const count = shadow(owner).querySelector(".count")!.textContent;
      const afterChurn = stats();

      shadow(owner).querySelector<HTMLButtonElement>(".late")!.click();
      owner.remove();
      await wait(500);
      const afterUnmount = stats();

      shadow(peer).querySelector<HTMLButtonElement>(".sync")!.click();
      await wait(100);
      const seen = shadow(peer).querySelector(".seen")!.textContent;
      peer.remove();
      await wait(100);
      const finalStats = stats();
      return { before, afterChurn, afterUnmount, finalStats, payload, count, seen };
    });

    expect(result.payload).toBe("payload-odd");
    expect(result.count).toBe("1000");
    expect(result.afterChurn.stateAllocated).toBeLessThanOrEqual(result.before.stateAllocated + 80);
    expect(result.afterChurn.stateObjects).toBeLessThanOrEqual(result.before.stateObjects + 80);
    expect(result.afterUnmount.components).toBe(1);
    expect(result.afterUnmount.timers).toBe(0);
    expect(result.afterUnmount.stateAllocated).toBeLessThan(result.afterChurn.stateAllocated);
    expect(result.seen).toBe("1");
    expect(result.finalStats.components).toBe(0);
    expect(result.finalStats.stateAllocated).toBeLessThanOrEqual(2);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});
