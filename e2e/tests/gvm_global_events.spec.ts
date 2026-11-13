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

  fs.writeFileSync(path.join(lib, "EventLoop.rb"), `
class EventLoop
  @tag_name = "event-loop"
  @calls
  @recoveries

  def initialize
    @calls = 0
    @recoveries = 0
  end

  def mounted
    Mochi.subscribe("loop", :repeat_loop)
    Mochi.subscribe("recovery", :recover)
  end

  def html
    %Q{<button class="loop" onclick="{start_loop}">Loop</button><button class="recovery" onclick="{start_recovery}">Recover</button><p class="calls">{@calls}</p><p class="recoveries">{@recoveries}</p>}
  end

  def start_loop
    Mochi.emit("loop", step: 0)
  end

  def repeat_loop(payload)
    @calls = @calls + 1
    Mochi.emit("loop", step: @calls)
  end

  def start_recovery
    Mochi.emit("recovery", ok: true)
  end

  def recover(payload)
    @recoveries = @recoveries + 1
  end
end
`);

  fs.writeFileSync(path.join(lib, "CycleA.rb"), `
class CycleA
  @tag_name = "cycle-a"
  @calls

  def initialize
    @calls = 0
  end

  def mounted
    Mochi.subscribe("cycle_a", :receive_a)
  end

  def html
    %Q{<button onclick="{begin_cycle}">Start cycle</button><p class="calls">{@calls}</p>}
  end

  def begin_cycle
    Mochi.emit("cycle_a", step: 0)
  end

  def receive_a(payload)
    @calls = @calls + 1
    Mochi.emit("cycle_b", step: @calls)
  end
end
`);

  fs.writeFileSync(path.join(lib, "CycleB.rb"), `
class CycleB
  @tag_name = "cycle-b"
  @calls

  def initialize
    @calls = 0
  end

  def mounted
    Mochi.subscribe("cycle_b", :receive_b)
  end

  def html
    %Q{<p class="calls">{@calls}</p>}
  end

  def receive_b(payload)
    @calls = @calls + 1
    Mochi.emit("cycle_a", step: @calls)
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
  <event-loop id="loop"></event-loop>
</body></html>
`);
}

async function waitForInitialComponents(page: any): Promise<void> {
  await page.evaluate(async () => {
    const tags = "event-publisher,event-subscriber,unregistered-listener,event-loop";
    const elements = Array.from(document.querySelectorAll(tags)) as any[];
    await Promise.all(elements.map((element) => element._mochiReady));
  });
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
  await waitForInitialComponents(page);

  const publisher = page.locator("#publisher");
  const first = page.locator("#first");
  const second = page.locator("#second");
  const unregistered = page.locator("#unregistered");
  await page.evaluate(() => {
    (window as any).__outboxes = [];
    const element = document.querySelector("#publisher") as any;
    const module = element._mochiModule;
    const clear = module._mochi_emit_outbox_clear.bind(module);
    module._mochi_emit_outbox_clear = () => {
      const offset = module._mochi_emit_outbox_offset();
      const length = module._mochi_emit_outbox_len();
      (window as any).__outboxes.push(new TextDecoder().decode(module.HEAPU8.subarray(offset, offset + length)));
      return clear();
    };
  });
  await publisher.locator("button").click();
  console.log("DEBUG emit", await page.evaluate(() => ({
    outboxes: (window as any).__outboxes,
    stats: (window as any).MochiLoader.debugStats(),
  })));
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

test("Ruby event loops stop at profile capacity and later events recover", async ({ page }) => {
  setupConsoleLogging(page);
  await page.addInitScript(() => {
    (window as any).__mochiErrors = [];
    document.addEventListener("mochi:error", (event: Event) => {
      (window as any).__mochiErrors.push((event as CustomEvent).detail);
    });
  });
  await page.goto(`${baseURL}/index.html`);
  await waitForInitialComponents(page);

  const capacities = await page.evaluate(async () => {
    const manifest = await (await fetch("mochi-manifest.json")).json();
    return {
      entries: manifest.capacity_profile.capacities.host_event_queue_entries,
      bytes: manifest.capacity_profile.capacities.host_event_queue_bytes,
      helperPackages: Object.keys(manifest.packages).filter((name) => /global[-_]?events/i.test(name)),
    };
  });
  expect(capacities.entries).toBeGreaterThan(0);
  expect(capacities.bytes).toBeGreaterThan(0);
  expect(capacities.helperPackages).toEqual([]);

  const loop = page.locator("#loop");
  await loop.locator("button.loop").click();
  await expect(loop.locator(".calls")).toHaveText(String(capacities.entries));
  const errors = await page.evaluate(() => (window as any).__mochiErrors);
  expect(errors).toHaveLength(1);
  expect(errors[0].phase).toBe("event");
  expect(errors[0].event).toBe("loop");
  expect(errors[0].callback).toBe("repeat_loop");
  expect(errors[0].publisher).toBeTruthy();
  expect(errors[0].subscriber).toBe(errors[0].publisher);
  expect(errors[0].source).toMatch(/EventLoop\.rb:/);

  await loop.locator("button.recovery").click();
  await expect(loop.locator(".recoveries")).toHaveText("1");
  expect(await page.evaluate(() => (window as any).__mochiErrors)).toHaveLength(1);
});

test("two Ruby components stop an A-to-B-to-A event cycle at the profile bound", async ({ page }) => {
  setupConsoleLogging(page);
  await page.addInitScript(() => {
    (window as any).__mochiErrors = [];
    document.addEventListener("mochi:error", (event: Event) => {
      (window as any).__mochiErrors.push((event as CustomEvent).detail);
    });
  });
  await page.goto(`${baseURL}/index.html`);
  await waitForInitialComponents(page);
  const capacities = await page.evaluate(async () => {
    const manifest = await (await fetch("mochi-manifest.json")).json();
    return manifest.capacity_profile.capacities.host_event_queue_entries;
  });
  await page.evaluate(() => {
    const a = document.createElement("cycle-a");
    const b = document.createElement("cycle-b");
    a.id = "cycle-a-instance";
    b.id = "cycle-b-instance";
    document.body.append(a, b);
  });
  const a = page.locator("#cycle-a-instance");
  const b = page.locator("#cycle-b-instance");
  await Promise.all([
    a.evaluate((element: any) => element._mochiReady),
    b.evaluate((element: any) => element._mochiReady),
  ]);
  await a.locator("button").click();

  await expect(a.locator(".calls")).toHaveText(String(Math.ceil(capacities / 2)));
  await expect(b.locator(".calls")).toHaveText(String(Math.floor(capacities / 2)));
  const errors = await page.evaluate(() => (window as any).__mochiErrors);
  expect(errors).toHaveLength(1);
  expect(errors[0].phase).toBe("event");
  expect(["cycle_a", "cycle_b"]).toContain(errors[0].event);
  expect(["receive_a", "receive_b"]).toContain(errors[0].callback);
  expect(errors[0].source).toMatch(/Cycle[AB]\.rb:\d+/);
  const stats = await page.evaluate(() => (window as any).MochiLoader.debugStats());
  expect(stats.globalEventQueueEntries).toBe(0);
  expect(stats.globalEventQueueBytes).toBe(0);

  await page.evaluate(() => {
    document.querySelector("#cycle-a-instance")?.remove();
    document.querySelector("#cycle-b-instance")?.remove();
  });
  await expect.poll(async () => (await page.evaluate(() => (window as any).MochiLoader.debugStats())).globalEventSubscribers)
    .toBe(2);
});

test("unmounted and remounted components release and renew event subscriptions", async ({ page }) => {
  setupConsoleLogging(page);
  await page.goto(`${baseURL}/index.html`);
  await waitForInitialComponents(page);
  const stats = () => page.evaluate(() => (window as any).MochiLoader.debugStats());
  await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(4);

  await page.evaluate(() => document.querySelector("#second")?.remove());
  await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(3);
  await page.evaluate(() => {
    const replacement = document.createElement("event-subscriber");
    replacement.id = "second-replacement";
    document.body.appendChild(replacement);
  });
  await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(4);

  await page.locator("#publisher button").click();
  await expect(page.locator("#first .deliveries")).toHaveText("1");
  await expect(page.locator("#second-replacement .deliveries")).toHaveText("1");
  await page.evaluate(() => {
    document.querySelector("#first")?.remove();
    document.querySelector("#second-replacement")?.remove();
  });
  await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(2);
  for (let cycle = 0; cycle < 3; cycle += 1) {
    await page.evaluate((index) => {
      const first = document.createElement("event-subscriber");
      const second = document.createElement("event-subscriber");
      first.id = `cycle-${index}-first`;
      second.id = `cycle-${index}-second`;
      document.body.append(first, second);
    }, cycle);
    await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(4);
    await page.evaluate((index) => {
      document.querySelector(`#cycle-${index}-first`)?.remove();
      document.querySelector(`#cycle-${index}-second`)?.remove();
    }, cycle);
    await expect.poll(async () => (await stats()).globalEventSubscribers).toBe(2);
  }
  const finalStats = await stats();
  expect(finalStats.globalEventQueueEntries).toBe(0);
  expect(finalStats.globalEventQueueBytes).toBe(0);
});
