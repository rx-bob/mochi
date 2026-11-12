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
  prop :label, String, default: "unset"
  prop :count, Integer, default: 0
  prop :flag, Boolean, default: false
  prop :note, String
  prop :rows, Array, default: []
  prop :meta, Hash, default: {}

  @summary
  @ready

  def initialize
    @summary = "#{@label}:#{@count}:#{@flag}:#{note_text_initial}"
    @ready = "ready"
  end

  def note_text_initial
    @note.nil? ? "nil" : @note
  end

  def html
    %Q{
      <span class="badge-text">{@label}</span>
      <span class="badge-count">{@count}</span>
      <span class="badge-flag">{@flag}</span>
      <span class="badge-note">{note_text}</span>
      <span class="badge-rows">{row_count}</span>
      <span class="badge-currency">{currency}</span>
      <span class="badge-init">{@summary}</span>
      <span class="badge-pair">{badge_pair}</span>
      <span class="badge-ready">{@ready}</span>
      <button class="badge-mutate" onclick="{add_row}">Mutate</button>
    }
  end

  def note_text
    @note.nil? ? "nil" : @note
  end

  def row_count
    @rows.length
  end

  def currency
    @meta["currency"]
  end

  def badge_pair
    "#{@label}:#{@count}"
  end

  def add_row
    @rows << {"id" => "extra"}
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
  @badge_label
  @badge_count
  @badge_flag
  @badge_note
  @badge_rows
  @badge_meta
  @parent_rows

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
    @badge_label = "synced-prop"
    @badge_count = 0
    @badge_flag = false
    @badge_note = nil
    @badge_rows = [
      {"id" => "r1", "label" => "One"},
      {"id" => "r2", "label" => "Two"}
    ]
    @badge_meta = {"currency" => "USD"}
    @parent_rows = @badge_rows
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
        <button class="badge-update" onclick="{bump_badge}">Badge</button>
        <button class="badge-invalid" onclick="{break_badge_count}">Invalid</button>
        <button class="badge-fix" onclick="{fix_badge_count}">Fix</button>
        <p class="parent-rows">{@parent_rows.length}</p>
        <child-badge
          class="typed-badge"
          label="{@badge_label}"
          count="{@badge_count}"
          flag="{@badge_flag}"
          note="{@badge_note}"
          rows="{@badge_rows}"
          meta="{@badge_meta}"
        ></child-badge>
        <child-badge class="defaults-badge"></child-badge>
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

  def bump_badge
    @badge_label = @badge_label == "synced-prop" ? "live-prop" : "live-prop-2"
    @badge_count = @badge_count + 1
    @badge_flag = !@badge_flag
  end

  def break_badge_count
    @badge_count = "not-a-count"
  end

  def fix_badge_count
    @badge_count = 5
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

    // The badge prop arrives through a live parent attribute. Updating it
    // after both components are mounted must keep the same child instance
    // and node while the child text follows the new value.
    const badge = host.locator("child-badge.typed-badge");
    await expect(badge.locator("span.badge-text")).toHaveText("synced-prop");
    await expect(badge.locator("span.badge-count")).toHaveText("0");
    await expect(badge.locator("span.badge-flag")).toHaveText("false");
    await expect(badge.locator("span.badge-note")).toHaveText("nil");
    await expect(badge.locator("span.badge-rows")).toHaveText("2");
    await expect(badge.locator("span.badge-currency")).toHaveText("USD");
    await expect(badge.locator("span.badge-pair")).toHaveText("synced-prop:0");

    // A child mounted without any attributes observes declared defaults while
    // initialize runs, not placeholder text or an unset ivar.
    const defaultsBadge = host.locator("child-badge.defaults-badge");
    await expect(defaultsBadge.locator("span.badge-init")).toHaveText("unset:0:false:nil");
    await expect(defaultsBadge.locator("span.badge-ready")).toHaveText("ready");
    await expect(defaultsBadge.locator("span.badge-rows")).toHaveText("0");

    const badgeInstance = await badge.evaluate((element: any) => {
      element.__badgeIdentity = true;
      return element._mochiInstance;
    });
    expect(badgeInstance).toBeTruthy();

    await host.locator("button.badge-update").click();
    await expect(badge.locator("span.badge-text")).toHaveText("live-prop");
    await expect(badge.locator("span.badge-count")).toHaveText("1");
    await expect(badge.locator("span.badge-flag")).toHaveText("true");
    // Three related props update in one batch, so no frame can expose the new
    // label with the previous count.
    await expect(badge.locator("span.badge-pair")).toHaveText("live-prop:1");
    await expect(badge).toHaveAttribute("label", "live-prop");
    expect(await badge.evaluate((element: any) => element._mochiInstance)).toBe(badgeInstance);
    expect(await badge.evaluate((element: any) => element.__badgeIdentity)).toBe(true);

    await host.locator("button.badge-update").click();
    await expect(badge.locator("span.badge-text")).toHaveText("live-prop-2");
    await expect(badge.locator("span.badge-count")).toHaveText("2");
    await expect(badge.locator("span.badge-flag")).toHaveText("false");
    await expect(badge.locator("span.badge-pair")).toHaveText("live-prop-2:2");
    expect(await badge.evaluate((element: any) => element._mochiInstance)).toBe(badgeInstance);
    expect(await badge.evaluate((element: any) => element.__badgeIdentity)).toBe(true);

    // An invalid typed value is rejected with the prop declaration location
    // and the child keeps its last valid input.
    await page.evaluate(() => {
      (window as any).__mochiPropErrors = [];
      document.addEventListener("mochi:error", (event: any) => {
        (window as any).__mochiPropErrors.push(event.detail);
      });
    });
    await host.locator("button.badge-invalid").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiPropErrors.length,
    )).toBe(1);
    const propError = await page.evaluate(() => (window as any).__mochiPropErrors[0]);
    expect(propError.phase).toBe("attribute");
    expect(propError.property).toBe("count");
    expect(propError.propType).toBe("integer");
    expect(propError.source).toMatch(/ChildBadge\.rb:\d+/);
    await expect(badge.locator("span.badge-count")).toHaveText("2");

    await host.locator("button.badge-fix").click();
    await expect(badge.locator("span.badge-count")).toHaveText("5");
    await expect(badge.locator("span.badge-pair")).toHaveText("live-prop-2:5");

    // The child receives a private collection snapshot. Mutating it cannot
    // change the parent's rows.
    await expect(host.locator("p.parent-rows")).toHaveText("2");
    await badge.locator("button.badge-mutate").click();
    await expect(badge.locator("span.badge-rows")).toHaveText("3");
    await expect(host.locator("p.parent-rows")).toHaveText("2");

    // Removing a typed-prop child disposes its instance. A later mount builds
    // a fresh instance from current attributes instead of reusing the snapshot.
    const disposed = await badge.evaluate((element: any) => new Promise((resolve) => {
      element.remove();
      setTimeout(() => resolve(element._mochiUnmounted), 0);
    }));
    expect(disposed).toBe(true);
    await expect(host.locator("child-badge.typed-badge")).toHaveCount(0);

    await host.evaluate((element: any) => {
      const remounted = document.createElement("child-badge");
      remounted.className = "remount-badge";
      remounted.setAttribute("label", "fresh");
      remounted.setAttribute("count", "7");
      remounted.setAttribute("rows", '[{"id":"x"}]');
      element.shadowRoot.appendChild(remounted);
      return remounted._mochiReady.then(() => true);
    });
    const remountBadge = host.locator("child-badge.remount-badge");
    await expect(remountBadge.locator("span.badge-pair")).toHaveText("fresh:7");
    await expect(remountBadge.locator("span.badge-rows")).toHaveText("1");
    expect(await remountBadge.evaluate((element: any) => element._mochiInstance))
      .not.toBe(badgeInstance);

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

      const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
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
      await settle();
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

test("moving a component preserves state and reinsertion after disposal rebuilds it", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-reconnect-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "LifecycleChild.rb"), `
class LifecycleChild
  @tag_name = "lifecycle-child"
  @label
  @draft
  @clicks

  def initialize
    @label = "unset"
    @draft = "ready"
    @clicks = 0
  end

  def html
    %Q{
      <div class="lifecycle-child">
        <p class="label">{@label}</p>
        <input class="draft" type="text" bind:value="@draft">
        <p class="draft-out">{@draft}</p>
        <button class="bump" onclick="{bump}">Bump</button>
        <p class="clicks">{@clicks}</p>
      </div>
    }
  end

  def bump
    @clicks += 1
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "LifecycleHost.rb"), `
class LifecycleHost
  @tag_name = "lifecycle-host"

  def html
    %Q{
      <div class="lifecycle-host">
        <div class="children">
          <lifecycle-child label="alpha"></lifecycle-child>
          <lifecycle-child label="beta"></lifecycle-child>
        </div>
      </div>
    }
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
    <lifecycle-host></lifecycle-host>
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
      const host = document.querySelector("lifecycle-host") as any;
      const children = host && host.shadowRoot
        ? Array.from(host.shadowRoot.querySelectorAll("lifecycle-child")) as any[]
        : [];
      return host && host._mochiMountState === "mounted" && children.length === 2 &&
        children.every((child) => child._mochiMountState === "mounted");
    });

    const host = page.locator("lifecycle-host");
    const children = host.locator(".children lifecycle-child");
    await expect(children).toHaveCount(2);
    const alpha = children.nth(0);
    await expect(alpha.locator("p.label")).toHaveText("alpha");

    await alpha.locator("input.draft").fill("edited");
    await expect(alpha.locator("p.draft-out")).toHaveText("edited");
    await alpha.locator("button.bump").click();
    await expect(alpha.locator("p.clicks")).toHaveText("1");

    const before = await page.evaluate(() => {
      const root = document.querySelector("lifecycle-host") as any;
      const boxes = Array.from(root.shadowRoot.querySelectorAll("lifecycle-child")) as any[];
      const first = boxes[0];
      return {
        token: first._mochiMountToken as number,
        instance: String(first._mochiInstance),
        stats: (window as any).MochiLoader.debugStats(),
      };
    });

    // A renderer move removes and reinserts the node in the same turn. The
    // instance, edited draft, and click count must survive without remounting.
    const moved = await page.evaluate(async () => {
      const root = document.querySelector("lifecycle-host") as any;
      const box = root.shadowRoot.querySelector(".children") as Element;
      const kids = Array.from(box.querySelectorAll("lifecycle-child")) as any[];
      box.appendChild(kids[0]);
      await new Promise((resolve) => setTimeout(resolve, 0));
      const alpha = (Array.from(box.querySelectorAll("lifecycle-child")) as any[])[1];
      return {
        token: alpha._mochiMountToken as number,
        instance: String(alpha._mochiInstance),
        label: alpha.shadowRoot.querySelector(".label").textContent,
        draft: alpha.shadowRoot.querySelector("input.draft").value,
        clicks: alpha.shadowRoot.querySelector(".clicks").textContent,
        stats: (window as any).MochiLoader.debugStats(),
      };
    });

    expect(moved.token).toBe(before.token);
    expect(moved.instance).toBe(before.instance);
    expect(moved.label).toBe("alpha");
    expect(moved.draft).toBe("edited");
    expect(moved.clicks).toBe("1");
    expect(moved.stats.components).toBe(before.stats.components);
    expect(moved.stats.bindings).toBe(before.stats.bindings);
    expect(moved.stats.elements).toBe(before.stats.elements);

    // Repeated moves must not stack hooks, listeners, or VM registrations.
    const repeated = await page.evaluate(async () => {
      const root = document.querySelector("lifecycle-host") as any;
      const box = root.shadowRoot.querySelector(".children") as Element;
      const alpha = (Array.from(box.querySelectorAll("lifecycle-child")) as any[])
        .find((child) => child.shadowRoot.querySelector(".label").textContent === "alpha");
      for (let index = 0; index < 12; index += 1) {
        box.insertBefore(alpha, box.firstElementChild);
        box.appendChild(alpha);
      }
      await new Promise((resolve) => setTimeout(resolve, 0));
      return {
        token: alpha._mochiMountToken as number,
        instance: String(alpha._mochiInstance),
        draft: alpha.shadowRoot.querySelector("input.draft").value,
        clicks: alpha.shadowRoot.querySelector(".clicks").textContent,
        stats: (window as any).MochiLoader.debugStats(),
      };
    });

    expect(repeated.token).toBe(before.token);
    expect(repeated.instance).toBe(before.instance);
    expect(repeated.draft).toBe("edited");
    expect(repeated.clicks).toBe("1");
    expect(repeated.stats.components).toBe(before.stats.components);
    expect(repeated.stats.bindings).toBe(before.stats.bindings);
    expect(repeated.stats.elements).toBe(before.stats.elements);

    await children.nth(1).locator("button.bump").click();
    await expect(children.nth(1).locator("p.clicks")).toHaveText("2");

    // Removal through the deferred disposal boundary, then reinsertion, must
    // produce a fresh instance with rebuilt props and working handlers.
    const rebuilt = await page.evaluate(async () => {
      const root = document.querySelector("lifecycle-host") as any;
      const box = root.shadowRoot.querySelector(".children") as Element;
      const alpha = (Array.from(box.querySelectorAll("lifecycle-child")) as any[])
        .find((child) => child.shadowRoot.querySelector(".label").textContent === "alpha");
      const beforeRemoval = (window as any).MochiLoader.debugStats();
      const token = alpha._mochiMountToken as number;
      const instance = String(alpha._mochiInstance);
      alpha.remove();
      await new Promise((resolve) => setTimeout(resolve, 0));
      const removed = (window as any).MochiLoader.debugStats();
      box.appendChild(alpha);
      await alpha._mochiReady;
      return {
        token,
        instance,
        beforeRemoval,
        removed,
        after: {
          token: alpha._mochiMountToken as number,
          instance: String(alpha._mochiInstance),
          state: alpha._mochiMountState,
          label: alpha.shadowRoot.querySelector(".label").textContent,
          draft: alpha.shadowRoot.querySelector("input.draft").value,
          draftOut: alpha.shadowRoot.querySelector(".draft-out").textContent,
          clicks: alpha.shadowRoot.querySelector(".clicks").textContent,
          stats: (window as any).MochiLoader.debugStats(),
        },
      };
    });

    expect(rebuilt.removed.components).toBe(rebuilt.beforeRemoval.components - 1);
    expect(rebuilt.removed.elements).toBe(rebuilt.beforeRemoval.elements - 1);
    expect(rebuilt.after.token).toBeGreaterThan(rebuilt.token);
    expect(rebuilt.after.instance).not.toBe(rebuilt.instance);
    expect(rebuilt.after.state).toBe("mounted");
    expect(rebuilt.after.label).toBe("alpha");
    expect(rebuilt.after.draft).toBe("ready");
    expect(rebuilt.after.draftOut).toBe("ready");
    expect(rebuilt.after.clicks).toBe("0");
    expect(rebuilt.after.stats.components).toBe(rebuilt.beforeRemoval.components);
    expect(rebuilt.after.stats.bindings).toBe(rebuilt.beforeRemoval.bindings);
    expect(rebuilt.after.stats.elements).toBe(rebuilt.beforeRemoval.elements);

    await children.nth(1).locator("input.draft").fill("fresh");
    await expect(children.nth(1).locator("p.draft-out")).toHaveText("fresh");
    await children.nth(1).locator("button.bump").click();
    await expect(children.nth(1).locator("p.clicks")).toHaveText("1");
    await children.nth(1).evaluate((element) => element.setAttribute("label", "gamma"));
    await expect(children.nth(1).locator("p.label")).toHaveText("gamma");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("helper calls keep arguments and later definitions work from every path", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-helpers-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "MathHelper.rb"), `
class MathHelper
  def self.scaled(value, factor)
    (value * factor).to_s
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "HelperProbe.rb"), `
class HelperProbe
  @tag_name = "helper-probe"
  @total
  @status
  @initial
  @count

  def initialize
    @total = 1234
    @count = 0
    @status = "idle"
    @initial = rebuild
  end

  def rebuild
    wrap(number(@total), " init")
  end

  def number(value)
    value.to_s
  end

  def wrap(value, suffix)
    value + suffix
  end

  def total_label
    compact(@total)
  end

  def compact(value)
    value.to_s + " total"
  end

  def html
    %Q{
      <div class="helper-probe">
        <p class="direct">{number(@total)}</p>
        <p class="later">{total_label}</p>
        <p class="later-direct">{compact(@total)}</p>
        <p class="nested">{wrap(number(@total), " nested")}</p>
        <p class="class-helper">{MathHelper.scaled(@total, 2)}</p>
        <p class="initial">{@initial}</p>
        <p class="status">{@status}</p>
        <p class="count">{@count}</p>
        <button class="bump" onclick="{bump}">Bump</button>
        <button class="apply" onclick="{apply(5)}">Apply</button>
      </div>
    }
  end

  def bump
    @total += 1
  end

  def apply(value)
    @count += value
    @status = "count=#{@count} label=#{total_label} direct=#{number(@total)} class=#{MathHelper.scaled(@total, 3)}"
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "BrokenHelper.rb"), `
class BrokenHelper
  @tag_name = "broken-helper"
  @value

  def initialize
    @value = 1
  end

  def html
    %Q{<span class="broken">{missing_helper(@value)}</span>}
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "WrongArityHelper.rb"), `
class WrongArityHelper
  @tag_name = "wrong-arity-helper"
  @value

  def initialize
    @value = 1
  end

  def number(value)
    value.to_s
  end

  def html
    %Q{<span class="arity">{number(@value, 2)}</span>}
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
    <helper-probe></helper-probe>
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
    const probe = page.locator("helper-probe");
    await expect(probe.locator("p.direct")).toHaveText("1234");
    await expect(probe.locator("p.later")).toHaveText("1234 total");
    await expect(probe.locator("p.later-direct")).toHaveText("1234 total");
    await expect(probe.locator("p.nested")).toHaveText("1234 nested");
    await expect(probe.locator("p.class-helper")).toHaveText("2468");
    await expect(probe.locator("p.initial")).toHaveText("1234 init");

    await probe.locator("button.bump").click();
    await expect(probe.locator("p.direct")).toHaveText("1235");
    await expect(probe.locator("p.later")).toHaveText("1235 total");
    await expect(probe.locator("p.later-direct")).toHaveText("1235 total");
    await expect(probe.locator("p.nested")).toHaveText("1235 nested");
    await expect(probe.locator("p.class-helper")).toHaveText("2470");

    await probe.locator("button.apply").click();
    await expect(probe.locator("p.count")).toHaveText("5");
    await expect(probe.locator("p.status")).toHaveText(
      "count=5 label=1235 total direct=1235 class=3705",
    );

    const failures = await page.evaluate(async () => {
      const wait = () => new Promise((resolve) => setTimeout(resolve, 0));
      const mountFailure = async (tag: string) => {
        const element = document.createElement(tag) as any;
        document.body.appendChild(element);
        let message = "";
        try {
          await element._mochiReady;
        } catch (error) {
          message = String((error as Error).message ?? error);
        }
        const state = element._mochiMountState;
        const instance = element._mochiInstance;
        element.remove();
        await wait();
        return { message, state, instance, stats: (window as any).MochiLoader.debugStats() };
      };
      return {
        missing: await mountFailure("broken-helper"),
        arity: await mountFailure("wrong-arity-helper"),
      };
    });

    expect(failures.missing.message).toContain("BrokenHelper");
    expect(failures.missing.message).toContain("__mochi_bind_0");
    expect(failures.missing.message).toContain("unknown method");
    expect(failures.missing.message).toContain("lib/BrokenHelper.rb:");
    expect(failures.arity.message).toContain("WrongArityHelper");
    expect(failures.arity.message).toContain("__mochi_bind_0");
    expect(failures.arity.message).toContain("wrong number of arguments");
    expect(failures.arity.message).toContain("lib/WrongArityHelper.rb:");
    expect(failures.missing.state).toBe("failed");
    expect(failures.arity.state).toBe("failed");
    expect(failures.missing.instance).toBeNull();
    expect(failures.arity.instance).toBeNull();
    expect(failures.missing.stats.components).toBe(1);
    expect(failures.arity.stats.components).toBe(1);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("nested template expressions keep hashes, quoted braces, and event arguments", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-expressions-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "NestedProbe.rb"), `
class NestedProbe
  @tag_name = "nested-probe"
  @record
  @status

  def initialize
    @record = { label: "alpha", meta: { suffix: "}" } }
    @status = "idle"
  end

  def format_record(record, suffix)
    "#{record[:label]}#{suffix}"
  end

  def html
    %Q[
      <div class="nested-probe">
        <p class="nested">{format_record(@record, @record[:meta][:suffix])}</p>
        <span class="literal">Literal café {{braces}} and {format_record(@record, "}")}</span>
        <a class="attr" title="{format_record(@record, @record[:meta][:suffix])}">link</a>
        <button class="act" onclick="{apply(@record[:label])}">Apply</button>
        <p class="status">{@status}</p>
      </div>
    ]
  end

  def apply(value)
    @status = "picked=#{value}"
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
    <nested-probe></nested-probe>
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
    const probe = page.locator("nested-probe");
    await expect(probe.locator("p.nested")).toHaveText("alpha}");
    await expect(probe.locator("span.literal")).toHaveText("Literal café {braces} and alpha}");
    await expect(probe.locator("a.attr")).toHaveAttribute("title", "alpha}");

    await probe.locator("button.act").click();
    await expect(probe.locator("p.status")).toHaveText("picked=alpha");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("scoped list rows keep typed ids through filtering, reordering, and nested events", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-scoped-lists-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "ScopedListProbe.rb"), `
class ListStateBadge
  @tag_name = "list-state-badge"
  @count

  def initialize
    @count = 0
  end

  def increment
    @count += 1
  end

  def html
    %Q{
      <span class="badge-count">{@count}</span>
      <button class="badge-increment" onclick="{increment}">badge+</button>
    }
  end
end

class ScopedListProbe
  @tag_name = "scoped-list-probe"
  @events
  @selected
  @suffix

  def initialize
    @events = [
      {"id" => "a", "label" => "Alpha", "children" => ["a1", "a2"]},
      {"id" => "b", "label" => "Beta", "children" => ["b1"]}
    ]
    @selected = "none"
    @suffix = "!"
  end

  def label(ev)
    ev["label"] + @suffix
  end

  def open_event(id, idx)
    @selected = id + ":" + idx.to_s
  end

  def pick_child(parent_id, child, child_index)
    @selected = parent_id + ":" + child + ":" + child_index.to_s
  end

  def filter_beta
    kept = []
    @events.each do |event|
      if event["id"] == "b"
        kept.push(event)
      end
    end
    @events = kept
  end

  def reorder
    @events = [@events[1], @events[0]]
  end

  def bump_suffix
    @suffix = @suffix + "?"
  end

  def html
    %Q{
      <div class="probe">
        <p class="selected">{@selected}</p>
        <button class="filter" onclick="{filter_beta}">Filter</button>
        <button class="reorder" onclick="{reorder}">Reorder</button>
        <button class="bump" onclick="{bump_suffix}">Bump</button>
        <ul class="events">
          {each @events as ev, idx, key: ev["id"]}
            <li class="row" data-row="{ev["id"]}">
              <input class="draft">
              <button class="open" onclick="{open_event(ev["id"], idx)}">{label(ev)}</button>
              <list-state-badge></list-state-badge>
              <span class="children">{each ev["children"] as child, ci, key: child}<button class="child" onclick="{pick_child(ev["id"], child, ci)}">{child}@{ev["id"]}:{ci}</button>{end}</span>
            </li>
          {end}
        </ul>
      </div>
    }
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
    <scoped-list-probe></scoped-list-probe>
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
    const probe = page.locator("scoped-list-probe");
    const rows = probe.locator("li.row");

    await expect(rows).toHaveCount(2);
    await expect(rows.nth(0).locator("button.open")).toHaveText("Alpha!");
    await expect(rows.nth(1).locator("button.open")).toHaveText("Beta!");
    await expect(rows.nth(0).locator(".children")).toHaveText("a1@a:0a2@a:1");

    await rows.nth(1).locator("button.open").click();
    await expect(probe.locator("p.selected")).toHaveText("b:1");

    await rows.nth(0).evaluate((row) => { (row as any).__probeIdentity = "alpha"; });
    await rows.nth(1).evaluate((row) => { (row as any).__probeIdentity = "beta"; });
    const alphaInput = rows.nth(0).locator("input.draft");
    await alphaInput.click();
    await alphaInput.fill("draft-alpha");
    await alphaInput.evaluate((input: HTMLInputElement) => input.setSelectionRange(1, 4));

    // A programmatic click changes the shared label without moving focus away
    // from the draft inside the list row.
    await probe.evaluate((element: any) => {
      element.shadowRoot.querySelector("button.bump").click();
    });
    await expect(rows.nth(0).locator("button.open")).toHaveText("Alpha!?");
    await expect(rows.nth(1).locator("button.open")).toHaveText("Beta!?");
    expect(await rows.nth(0).evaluate((row) => (row as any).__probeIdentity)).toBe("alpha");
    await expect(alphaInput).toHaveValue("draft-alpha");
    expect(await alphaInput.evaluate((input: HTMLInputElement) => {
      const root = input.getRootNode() as ShadowRoot;
      return {
        focused: root.activeElement === input,
        start: input.selectionStart,
        end: input.selectionEnd,
      };
    })).toEqual({ focused: true, start: 1, end: 4 });

    const alphaBadge = rows.nth(0).locator("list-state-badge");
    await alphaBadge.locator("button.badge-increment").click();
    await expect(alphaBadge.locator(".badge-count")).toHaveText("1");

    await probe.locator("button.reorder").click();
    await expect(rows.nth(0).locator("button.open")).toHaveText("Beta!?");
    await expect(rows.nth(1).locator("button.open")).toHaveText("Alpha!?");
    expect(await rows.nth(0).evaluate((row) => (row as any).__probeIdentity)).toBe("beta");
    expect(await rows.nth(1).evaluate((row) => (row as any).__probeIdentity)).toBe("alpha");
    await expect(rows.nth(1).locator("input.draft")).toHaveValue("draft-alpha");
    await expect(rows.nth(1).locator("list-state-badge .badge-count")).toHaveText("1");
    await rows.nth(0).locator("button.open").click();
    await expect(probe.locator("p.selected")).toHaveText("b:0");

    await rows.nth(1).locator("button.child").nth(1).click();
    await expect(probe.locator("p.selected")).toHaveText("a:a2:1");

    await probe.locator("button.filter").click();
    await expect(rows).toHaveCount(1);
    await expect(rows.nth(0).locator("button.open")).toHaveText("Beta!?");
    expect(await rows.nth(0).evaluate((row) => (row as any).__probeIdentity)).toBe("beta");
    await rows.nth(0).locator("button.open").click();
    await expect(probe.locator("p.selected")).toHaveText("b:0");
    await rows.nth(0).locator("button.child").click();
    await expect(probe.locator("p.selected")).toHaveText("b:b1:0");

    const rowText = await rows.nth(0).innerText();
    expect(rowText).not.toContain("{");
    expect(rowText).not.toContain("}");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("one Ruby file emits a screen, row component, and shared helper", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-multi-class-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "MultiPanel.rb"), `
class SharedLabels
  def self.label(value)
    "label-" + value.to_s
  end
end

class MultiRowBadge
  @tag_name = "multi-row-badge"
  @count

  def initialize
    @count = 10
  end

  def html
    %Q{
      <div class="row-badge">
        <span class="value">{SharedLabels.label(@count)}</span>
        <button class="increment" onclick="{increment}">row+</button>
      </div>
    }
  end

  def increment
    @count += 1
  end
end

class MultiScreenPanel
  @tag_name = "multi-screen-panel"
  @count

  def initialize
    @count = 0
  end

  def html
    %Q{
      <div class="screen-panel">
        <span class="value">{SharedLabels.label(@count)}</span>
        <button class="increment" onclick="{increment}">screen+</button>
      </div>
    }
  end

  def increment
    @count += 1
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
    <multi-row-badge></multi-row-badge>
    <multi-screen-panel></multi-screen-panel>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const manifest = JSON.parse(fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"));
  expect(manifest.components).toHaveLength(2);
  const helperNames = new Set(manifest.components.map((component: { helper_chi: string }) => component.helper_chi));
  expect(helperNames.size).toBe(1);
  const helperName = [...helperNames][0];
  expect(fs.existsSync(path.join(bundleDir, "components", helperName))).toBe(true);

  const helperRequests: string[] = [];
  page.on("request", (request) => {
    if (request.url().endsWith(".chi")) helperRequests.push(request.url());
  });

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    await page.waitForFunction(() => {
      const loader = (window as any).MochiLoader;
      return loader && loader.components.length === 2 &&
        window.customElements.get("multi-row-badge") &&
        window.customElements.get("multi-screen-panel");
    });

    const row = page.locator("multi-row-badge");
    const screen = page.locator("multi-screen-panel");
    await expect(row.locator(".value")).toHaveText("label-10");
    await expect(screen.locator(".value")).toHaveText("label-0");

    await screen.locator("button.increment").click();
    await expect(screen.locator(".value")).toHaveText("label-1");
    await expect(row.locator(".value")).toHaveText("label-10");

    await row.locator("button.increment").click();
    await expect(row.locator(".value")).toHaveText("label-11");
    await expect(screen.locator(".value")).toHaveText("label-1");

    expect(helperRequests.filter((url) => url.endsWith(helperName))).toHaveLength(1);
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

test("modal keeps backdrop-only close, focus containment, and opener restore", async ({ page }) => {
  test.skip(!fs.existsSync(senchaDistDir), "sencha/frontend-mochi/dist not built");
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(senchaDistDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  const focusedLabel = () => page.evaluate(() => {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) {
      active = active.shadowRoot.activeElement;
    }
    if (!active) return "";
    return active.getAttribute("aria-label") || (active.textContent || "").trim();
  });

  try {
    await page.goto(`${baseURL}/index.html`);
    await page.evaluate(() => {
      (window as unknown as { __mochiErrors: unknown[] }).__mochiErrors = [];
      document.addEventListener("mochi:error", (event) => {
        (window as unknown as { __mochiErrors: unknown[] }).__mochiErrors.push(
          (event as CustomEvent).detail
        );
      });
    });

    const root = page.locator("z-root");
    const topbar = root.locator("top-bar");
    const modal = root.locator("modal-container");
    const opener = topbar.locator('button[data-action="profile"]');

    await opener.click();
    const dialog = modal.locator(".modal");
    await expect(dialog).toBeVisible();
    await expect.poll(focusedLabel).toBe("Close dialog");

    // A click inside the dialog body must not reach the backdrop-only close.
    await dialog.locator(".modal-body").click();
    await expect(dialog).toBeVisible();

    // A true backdrop click closes and restores the opener.
    await modal.locator(".modal-backdrop").click({ position: { x: 5, y: 5 } });
    await expect(dialog).toHaveCount(0);
    await expect.poll(focusedLabel).toBe("Profile");

    // Reopen, then prove Tab/Shift-Tab wrap inside the dialog.
    await opener.click();
    await expect(dialog).toBeVisible();
    await expect.poll(focusedLabel).toBe("Close dialog");
    await page.keyboard.press("Shift+Tab");
    await expect.poll(focusedLabel).toBe("Done");
    await page.keyboard.press("Tab");
    await expect.poll(focusedLabel).toBe("Close dialog");

    // Escape closes and returns focus to the opener.
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
    await expect.poll(focusedLabel).toBe("Profile");

    const mochiErrors = await page.evaluate(() =>
      (window as unknown as { __mochiErrors: unknown[] }).__mochiErrors);
    expect(mochiErrors).toEqual([]);
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

test("form attributes distinguish boolean presence, textual values, and live properties", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-attributes-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "FormProbe.rb"), `
class FormProbe
  @tag_name = "form-probe"
  @query
  @checked
  @expanded
  @mode
  @count
  @note
  @note_step
  @status

  def initialize
    @query = "seed"
    @checked = false
    @expanded = false
    @mode = "idle"
    @count = 0
    @note = nil
    @note_step = 0
    @status = "idle"
  end

  def html
    %Q{
      <div class="probe">
        <p class="status">{@status}</p>
        <p data-role="classes" class="box {@mode} slot{@count}">classes</p>
        <input class="field" type="text" bind:value="@query">
        <input class="flag" type="checkbox" bind:checked="@checked">
        <button class="toggle" onclick="{toggle}" aria-expanded="{@expanded}">Toggle</button>
        <button class="busy" disabled="{@checked}">Busy</button>
        <button class="touch" onclick="{touch}">Touch</button>
        <button class="bump" onclick="{bump}">Bump</button>
        <button class="note-step" onclick="{note_step}">Note</button>
        <button class="rewrite" onclick="{rewrite}">Rewrite</button>
        <span class="note" data-note="{@note}">note</span>
        <span class="count" data-count="{@count}">count</span>
      </div>
    }
  end

  def toggle
    @expanded = !@expanded
  end

  def touch
    @status = "q=#{@query} checked=#{@checked}"
    @mode = @mode == "idle" ? "busy" : "idle"
  end

  def bump
    @count += 1
  end

  def note_step
    if @note_step == 0
      @note = ""
      @note_step = 1
    elsif @note_step == 1
      @note = "saved"
      @note_step = 2
    else
      @note = nil
      @note_step = 0
    end
  end

  def rewrite
    @query = "rewritten"
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
    <form-probe></form-probe>
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
    const probe = page.locator("form-probe");
    const classes = probe.locator("p[data-role='classes']");
    const toggle = probe.locator("button.toggle");
    const busy = probe.locator("button.busy");
    const field = probe.locator("input.field");
    const flag = probe.locator("input.flag");
    const note = probe.locator("span.note");

    await expect(classes).toHaveAttribute("class", "box idle slot0");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(note).not.toHaveAttribute("data-note", /.*/);
    await expect(probe.locator("span.count")).toHaveAttribute("data-count", "0");
    await expect(field).toHaveValue("seed");
    expect(await busy.evaluate((element) => element.hasAttribute("disabled"))).toBe(false);

    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");

    await flag.click();
    await expect(flag).toBeChecked();
    expect(await busy.evaluate((element) => element.hasAttribute("disabled"))).toBe(true);
    await flag.click();
    await expect(flag).not.toBeChecked();
    expect(await busy.evaluate((element) => element.hasAttribute("disabled"))).toBe(false);

    await probe.locator("button.note-step").click();
    await expect(note).toHaveAttribute("data-note", "");
    await probe.locator("button.note-step").click();
    await expect(note).toHaveAttribute("data-note", "saved");
    await probe.locator("button.note-step").click();
    await expect(note).not.toHaveAttribute("data-note", /.*/);

    await probe.locator("button.bump").click();
    await expect(probe.locator("span.count")).toHaveAttribute("data-count", "1");
    await expect(classes).toHaveAttribute("class", "box idle slot1");

    await probe.locator("button.touch").click();
    await expect(classes).toHaveAttribute("class", "box busy slot1");
    await expect(probe.locator("p.status")).toHaveText("q=seed checked=false");

    await field.click();
    await field.fill("hello");
    await field.evaluate((input: HTMLInputElement) => input.setSelectionRange(1, 3));
    await field.evaluate((input: HTMLInputElement) => { (input as any).__probeIdentity = "field"; });
    await flag.evaluate((input: HTMLInputElement) => { (input as any).__probeIdentity = "flag"; });

    // Programmatic click updates unrelated labels without moving focus from the
    // draft input. The input node, value, and selection must all survive.
    await probe.evaluate((element: any) => {
      element.shadowRoot.querySelector("button.touch").click();
    });
    await expect(probe.locator("p.status")).toHaveText("q=hello checked=false");
    await expect(classes).toHaveAttribute("class", "box idle slot1");
    expect(await field.evaluate((input: HTMLInputElement) => {
      const root = input.getRootNode() as ShadowRoot;
      return {
        identity: (input as any).__probeIdentity,
        value: input.value,
        focused: root.activeElement === input,
        start: input.selectionStart,
        end: input.selectionEnd,
      };
    })).toEqual({ identity: "field", value: "hello", focused: true, start: 1, end: 3 });
    expect(await flag.evaluate((input: HTMLInputElement) => (input as any).__probeIdentity)).toBe("flag");

    await probe.evaluate((element: any) => {
      element.shadowRoot.querySelector("button.rewrite").click();
    });
    await expect(field).toHaveValue("rewritten");
    expect(await field.evaluate((input: HTMLInputElement) => (input as any).__probeIdentity)).toBe("field");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});
