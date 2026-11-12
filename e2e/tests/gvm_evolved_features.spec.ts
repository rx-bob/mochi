import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";
import type { Locator } from "@playwright/test";
import { setupConsoleLogging } from "./test_utils";

test.describe.configure({ mode: "serial" });

const repoRoot = path.resolve(__dirname, "..", "..");
const compilerBinary = path.join(repoRoot, "compiler", "mochi");
const frontendRoot = process.env.MOCHI_FRONTEND_DIR || "";
const frontendDistDir = path.join(frontendRoot, "dist");

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
  ".woff2": "font/woff2",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

function startStaticServer(
  rootDir: string,
  options: {
    spaFallback?: boolean;
    apiHandler?: (request: http.IncomingMessage, response: http.ServerResponse) => boolean;
  } = {}
): Promise<{ server: http.Server; baseURL: string }> {
  const server = http.createServer((request, response) => {
    if (options.apiHandler && options.apiHandler(request, response)) return;
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
      if (error && options.spaFallback && path.extname(relative) === "") {
        fs.readFile(path.join(rootDir, "index.html"), (indexError, indexData) => {
          if (indexError) {
            response.writeHead(404);
            response.end();
            return;
          }
          response.writeHead(200, { "content-type": CONTENT_TYPES[".html"] });
          response.end(indexData);
        });
        return;
      }
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

function readManifest(bundleDir: string): any {
  return JSON.parse(fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"));
}

function readComponentDescriptor(bundleDir: string, manifest: any, tag: string): any {
  const entry = (manifest.components as any[]).find((component) => component.tag_name === tag);
  if (!entry) throw new Error(`missing component index entry ${tag}`);
  return JSON.parse(fs.readFileSync(path.join(bundleDir, entry.descriptor), "utf8"));
}

test("mochi test runs Ruby behavior tests against GVM bytecode and reports Ruby locations", async () => {
  test.setTimeout(180_000);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-ruby-tests-"));
  const bundleDir = path.join(projectDir, "production");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "test"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "ChildBadge.rb"), `
class ChildBadge
  @tag_name = "child-badge"
  prop :label, String, default: "before"

  def html
    %Q{<span class="label">{@label}</span>}
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "TestParent.rb"), `
class TestParent
  @tag_name = "test-parent"
  @label

  def initialize
    @label = "before"
  end

  def html
    %Q{
      <button class="change" onclick="{change}">Change</button>
      <child-badge label="{@label}"></child-badge>
    }
  end

  def change
    @label = "after"
  end

  def fail_at_runtime
    missing_runtime_method
  end
end
`);

  const testFile = path.join(projectDir, "test", "parent_test.rb");
  const writeTest = (body: string) => fs.writeFileSync(testFile, body);
  const runMochiTest = () => spawnSync(compilerBinary, ["test", "-i", projectDir], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env },
  });

  try {
    writeTest(`
Mochi::Test.test("parent value reaches child") do
  mount "test-parent"
  click ".change"
  wait_for_settled
  assert_text "child-badge >>> .label", "after"
end
`);
    const passing = runMochiTest();
    expect(passing.status, passing.stderr).toBe(0);
    expect(passing.stdout).toContain("PASS parent value reaches child");

    writeTest(`
Mochi::Test.test("wrong output assertion") do
  mount "test-parent"
  click ".change"
  wait_for_settled
  assert_text "child-badge >>> .label", "wrong"
end
`);
    const wrongAssertion = runMochiTest();
    expect(wrongAssertion.status).not.toBe(0);
    expect(wrongAssertion.stderr + wrongAssertion.stdout).toContain("parent_test.rb:");
    expect(wrongAssertion.stderr + wrongAssertion.stdout).toContain("expected 'wrong'");

    writeTest(`
Mochi::Test.test("caught runtime errors fail the test") do
  mount "test-parent"
  click ".explode"
  wait_for_settled
end
`);
    fs.writeFileSync(path.join(projectDir, "lib", "TestParent.rb"), `
class TestParent
  @tag_name = "test-parent"

  def html
    %Q{<button class="explode" onclick="{fail_at_runtime}">Explode</button>}
  end

  def fail_at_runtime
    missing_runtime_method
  end
end
`);
    const runtimeFailure = runMochiTest();
    expect(runtimeFailure.status).not.toBe(0);
    expect(runtimeFailure.stderr + runtimeFailure.stdout).toContain("TestParent.rb:");

    execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: "pipe",
    });
    const productionManifest = readManifest(bundleDir);
    expect(productionManifest.components.map((entry: any) => entry.tag_name)).toEqual([
      "child-badge",
      "test-parent",
    ]);
    expect(fs.existsSync(path.join(bundleDir, "test"))).toBe(false);
    expect(fs.readdirSync(bundleDir).some((entry) => entry.includes("test-runner"))).toBe(false);
  } finally {
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

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

test("two components share emitted CSS and selected icons in adopted and fallback paths", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-styles-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib", "styles"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "icons"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "styles", "reset.css"), `
:host { display: block; }
`);
  fs.writeFileSync(path.join(projectDir, "lib", "styles", "controls.css"), `
@import "reset.css";
.control {
  color: var(--ink);
  border: 1px solid var(--ink);
  padding: 3px;
}
`);
  fs.writeFileSync(path.join(projectDir, "lib", "StyleAlpha.rb"), `
class StyleAlpha
  @tag_name = "style-alpha"

  def html
    %Q{<button class="control alpha">{Mochi.raw(MochiIcons.icon("home"))}<span class="label">Alpha</span></button>}
  end

  def css
    %Q{
      @import "styles/controls.css";
      .control { background: rgb(255, 0, 0); }
    }
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "StyleBeta.rb"), `
class StyleBeta
  @tag_name = "style-beta"

  def html
    %Q{<button class="control beta">{Mochi.raw(MochiIcons.icon("home"))}<span class="label">Beta</span></button>}
  end

  def css
    %Q{
      @import "styles/controls.css";
      .control { background: rgb(0, 0, 255); }
    }
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "icons", "home.svg"),
    '<svg id="mochi-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M3 12h18"/></svg>\n');
  fs.writeFileSync(path.join(projectDir, "icons", "unused.svg"),
    '<svg id="mochi-icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/></svg>\n');
  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
      :root { --ink: #112233; }
      html[data-theme="dark"] { --ink: #aabbcc; }
    </style>
    <script src="mochi-loader.js"></script>
  </head>
  <body>
    <style-alpha></style-alpha>
    <style-beta></style-beta>
    <div id="fallback-root"></div>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const manifest = JSON.parse(fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"));
  const styleResources = Object.entries(manifest.resources as Record<string, any>)
    .filter(([, resource]) => resource.kind === "style");
  expect(styleResources).toHaveLength(2);
  styleResources.forEach(([, resource]) => {
    expect(resource.text).toBeUndefined();
    expect(fs.existsSync(path.join(bundleDir, resource.file))).toBe(true);
  });
  const alpha = readComponentDescriptor(bundleDir, manifest, "style-alpha");
  const beta = readComponentDescriptor(bundleDir, manifest, "style-beta");
  expect(alpha.style_resources).toEqual(beta.style_resources);
  expect(alpha.style_resources).toHaveLength(2);
  expect(fs.existsSync(path.join(bundleDir, "mochi-icons", "home.svg"))).toBe(true);
  expect(fs.existsSync(path.join(bundleDir, "mochi-icons", "unused.svg"))).toBe(false);

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));
  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const alphaCard = page.locator("style-alpha");
    const betaCard = page.locator("style-beta");
    await expect(alphaCard.locator("button.control")).toBeVisible();
    await expect(betaCard.locator("button.control")).toBeVisible();

    const adopted = await page.evaluate(() => {
      const first = (document.querySelector("style-alpha") as any).shadowRoot;
      const second = (document.querySelector("style-beta") as any).shadowRoot;
      return {
        first: first.adoptedStyleSheets ? first.adoptedStyleSheets.length : 0,
        second: second.adoptedStyleSheets ? second.adoptedStyleSheets.length : 0,
        feather: typeof (window as any).feather,
      };
    });
    expect(adopted.first).toBeGreaterThanOrEqual(3);
    expect(adopted.second).toBe(adopted.first);
    expect(adopted.feather).toBe("undefined");

    await expect(alphaCard.locator("button.control")).toHaveCSS("background-color", "rgb(255, 0, 0)");
    await expect(betaCard.locator("button.control")).toHaveCSS("background-color", "rgb(0, 0, 255)");
    await expect(alphaCard.locator("button.control")).toHaveCSS("color", "rgb(17, 34, 51)");
    await expect(alphaCard.locator("svg use")).toHaveAttribute("href", /mochi-icons\/home\.svg#mochi-icon$/);

    await page.evaluate(() => {
      document.documentElement.dataset.theme = "dark";
    });
    await expect(alphaCard.locator("button.control")).toHaveCSS("color", "rgb(170, 187, 204)");
    await expect(betaCard.locator("button.control")).toHaveCSS("color", "rgb(170, 187, 204)");

    const fallback = await page.evaluate(async () => {
      (window as any).CSSStyleSheet = undefined;
      const host = document.getElementById("fallback-root")!;
      const element = document.createElement("style-alpha");
      element.className = "fallback";
      host.appendChild(element);
      await (element as any)._mochiReady;
      const root = (element as any).shadowRoot;
      return {
        adopted: root.adoptedStyleSheets ? root.adoptedStyleSheets.length : 0,
        styles: root.querySelectorAll("style").length,
        shared: Array.from(root.querySelectorAll("style"))
          .filter((style) => style.hasAttribute("data-mochi-style-resource")).length,
      };
    });
    expect(fallback.adopted).toBe(0);
    expect(fallback.shared).toBe(2);
    expect(fallback.styles).toBe(3);

    const fallbackCard = page.locator("style-alpha.fallback");
    await expect(fallbackCard.locator("button.control")).toHaveCSS("background-color", "rgb(255, 0, 0)");
    await expect(fallbackCard.locator("button.control")).toHaveCSS("color", "rgb(170, 187, 204)");
    await page.evaluate(() => {
      delete document.documentElement.dataset.theme;
    });
    await expect(fallbackCard.locator("button.control")).toHaveCSS("color", "rgb(17, 34, 51)");

    expect(requested.some((url) => url.includes("feather"))).toBe(false);
    expect(requested.some((url) => url.includes("unused.svg"))).toBe(false);
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
  const helperNames = new Set(manifest.components.map((component: any) =>
    readComponentDescriptor(bundleDir, manifest, component.tag_name).helper_chi));
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

test.describe("Cowboy integration", () => {
test.beforeAll(() => {
  if (!frontendRoot || !fs.existsSync(path.join(frontendDistDir, "index.html"))) {
    test.skip(true, "Cowboy integration requires MOCHI_FRONTEND_DIR and a built frontend-mochi checkout");
  }
});

test("Cowboy frontend-mochi showcase works across all 8 screens with zero errors", async ({ page }) => {
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
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
    await expect(costs.locator(".costs-screen")).toHaveAttribute("data-usage-row-count", "126");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "6469040");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-input", "2074660");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cached", "3556200");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-output", "838180");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-requests", "2828");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cost-cents", "961");
    await expect(costs.locator("costs-daily-chart .day")).toHaveCount(7);
    await costs.locator('button[data-period="30"]').click();
    await expect(costs.locator(".costs-screen")).toHaveAttribute("data-usage-row-count", "540");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "27046540");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-input", "8699460");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cached", "14834500");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-output", "3512580");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-requests", "11883");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cost-cents", "4003");
    await expect(costs.locator("costs-daily-chart .day")).toHaveCount(30);
    for (const selector of ["costs-daily-chart .day", ".harness-row", ".component-row", "costs-model-table tbody [data-raw-total]"]) {
      const sum = await costs.locator(selector).evaluateAll((elements) =>
        elements.reduce((total, element) => total + Number(element.getAttribute("data-raw-total")), 0),
      );
      expect(sum, `${selector} should aggregate the shared usage rows`).toBe(27046540);
    }
    await costs.evaluate((host) => {
      const root = host.shadowRoot!;
      (window as any).__costsRefs = {
        summary: root.querySelector("costs-summary"),
        chart: root.querySelector("costs-daily-chart"),
        table: root.querySelector("costs-model-table"),
        components: new Map(Array.from(root.querySelectorAll(".component-row")).map((row) => [
          row.getAttribute("data-component-id"), row,
        ])),
      };
    });
    await costs.locator('button[data-harness="Codex"]').click();
    await expect(costs.locator(".costs-screen")).toHaveAttribute("data-usage-row-count", "180");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "8896860");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-input", "2903740");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cached", "4820900");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-output", "1172220");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-requests", "3969");
    await expect(costs.locator("costs-summary .summary-grid")).toHaveAttribute("data-raw-cost-cents", "1779");
    await expect(costs.locator("costs-model-table tbody tr")).toHaveCount(2);
    const preservedCostsNodes = await costs.evaluate((host) => {
      const root = host.shadowRoot!;
      const refs = (window as any).__costsRefs;
      const rows = Array.from(root.querySelectorAll(".component-row"));
      return {
        summary: root.querySelector("costs-summary") === refs.summary,
        chart: root.querySelector("costs-daily-chart") === refs.chart,
        table: root.querySelector("costs-model-table") === refs.table,
        componentRows: rows.map((row) => ({
          id: row.getAttribute("data-component-id"),
          same: refs.components.get(row.getAttribute("data-component-id")) === row,
        })),
      };
    });
    expect(preservedCostsNodes, "neighboring filters should preserve keyed Costs children and rows")
      .toEqual({ summary: true, chart: true, table: true, componentRows: expect.any(Array) });
    expect((preservedCostsNodes.componentRows as Array<{ id: string | null; same: boolean }>).every((row) => row.same),
      `existing keyed component rows should retain identity: ${JSON.stringify(preservedCostsNodes.componentRows)}`).toBe(true);

    // 5. Limits screen
    await topbar.locator('button[data-screen="limits"]').click();
    await expect(root.locator("limits-screen h1")).toHaveText("Usage limits");

    // 6. Logs screen filtering & drawer
    await topbar.locator('button[data-screen="logs"]').click();
    const logs = root.locator("logs-screen");
    await expect(logs.locator(".log-row")).toHaveCount(50);
    await expect(logs.locator(".logs-screen")).toHaveAttribute("data-retained-count", "480");
    await expect(logs.locator(".log-row[data-log-id='log-480'] .log-message")).toHaveText("Task completed successfully <img src=x onerror=alert(1)>");
    await expect(logs.locator("img[src='x']")).toHaveCount(0);
    await logs.locator('logs-results button[data-action="next-page"]').click();
    await expect(logs.locator(".log-row").first()).toHaveAttribute("data-log-id", "log-430");
    await logs.locator('button[data-action="sort"]').click();
    await expect(logs.locator(".log-row").first()).toHaveAttribute("data-log-id", "log-1");
    await logs.locator(".log-row").first().click();
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-1");
    await logs.locator('logs-results button[data-action="next-page"]').click();
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-1");
    await logs.locator('button[data-action="sort"]').click();
    await expect(logs.locator('button[data-action="sort"]')).toHaveText("Sort: newest first");
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-1");
    await logs.locator('button[data-level="error"]').click();
    await expect(logs.locator(".result-count")).toContainText("48 events");
    await expect(logs.locator(".log-row")).toHaveCount(48);
    await expect(logs.locator("aside.drawer")).toHaveCount(0);
    await logs.locator('button[data-project="cowboy-api"]').click();
    await expect(logs.locator(".result-count")).toContainText("16 events");
    await expect(logs.locator(".log-row").first()).toHaveAttribute("data-log-id", "log-476");
    await logs.locator(".log-row").first().click();
    await expect(logs.locator("aside.drawer h2")).toHaveText("error");
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-476");
    await logs.locator('aside.drawer button[data-action="close-drawer"]').click();
    await logs.locator('button[data-project="all"]').click();
    await logs.locator('button[data-level="all"]').click();
    await logs.locator("#log-query").fill("definitely absent");
    await logs.locator('button[data-action="apply-search"]').click();
    await expect(logs.locator(".result-count")).toContainText("0 events");
    await expect(logs.locator(".log-row")).toHaveCount(0);
    await logs.locator('button[data-action="clear-search"]').click();

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

test("Logs refresh is bounded, latest-wins, retryable, and disposed on navigation", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  const requested: string[] = [];
  let manualBatch = 0;
  let failureCount = 0;
  let finishDelayedResponse: (() => void) | null = null;
  const delayedResponseFinished = new Promise<void>((resolve) => {
    finishDelayedResponse = resolve;
  });

  const { server, baseURL } = await startStaticServer(frontendDistDir, {
    spaFallback: true,
    apiHandler: (request, response) => {
      if (new URL(request.url || "/", "http://localhost").pathname !== "/api/logs") return false;
      let bodyText = "";
      request.on("data", (chunk) => { bodyText += String(chunk); });
      request.on("end", () => {
        const body = JSON.parse(bodyText || "{}");
        requested.push(`${body.reason}:${body.level}:${body.query}`);
        const send = (status: number, payload: Record<string, unknown>) => {
          if (response.destroyed || response.writableEnded) return;
          response.writeHead(status, { "content-type": "application/json" });
          response.end(JSON.stringify(payload));
        };
        const label = body.query || body.level;
        if (body.query === "trigger-failure" && body.reason !== "retry") {
          failureCount += 1;
          send(500, { token: body.token, label, sequences: [] });
          return;
        }
        let sequences: number[] = [];
        if (body.reason === "manual") {
          const start = 481 + manualBatch * 1000;
          sequences = Array.from({ length: 1000 }, (_, index) => start + index);
          manualBatch += 1;
        }
        const delay = body.level === "error" ? 120
          : body.level === "info" && body.reason === "filter" ? 300
            : 10;
        setTimeout(() => {
          send(200, { token: body.token, label, sequences });
          if (body.level === "info" && body.reason === "filter") finishDelayedResponse?.();
        }, delay);
      });
      return true;
    },
  });
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("request", (request) => requested.push(`http:${new URL(request.url()).pathname}`));

  try {
    await page.goto(baseURL);
    const root = page.locator("z-root");
    await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");
    expect(requested.some((entry) => entry.includes("logs-screen.chi"))).toBe(false);
    expect(requested.some((entry) => entry === "http:/api/logs")).toBe(false);

    const topbar = root.locator("top-bar");
    await topbar.locator('button[data-screen="logs"]').click();
    const logs = root.locator("logs-screen");
    await expect(logs.locator(".refresh-toolbar")).toHaveAttribute("data-refresh-state", "ready");
    expect(requested.some((entry) => entry === "http:/api/logs")).toBe(true);
    expect(fs.existsSync(path.join(frontendDistDir, "test"))).toBe(false);
    expect(fs.readdirSync(frontendDistDir).some((entry) => /test-runner|api-fixture/i.test(entry))).toBe(false);

    await logs.locator('button[data-level="error"]').click();
    await logs.locator('button[data-level="warn"]').click();
    await expect(logs.locator(".refresh-status")).toHaveText("Synced: warn");

    await logs.locator("#log-query").fill("trigger-failure");
    await logs.locator('button[data-action="apply-search"]').click();
    await expect(logs.locator(".refresh-toolbar")).toHaveAttribute("data-refresh-state", "error");
    await expect(logs.locator(".refresh-error")).toContainText("HTTP 500");
    await expect(logs.locator('button[data-action="retry-refresh"]')).toBeVisible();
    await logs.locator('button[data-action="retry-refresh"]').click();
    await expect(logs.locator(".refresh-status")).toHaveText("Synced: trigger-failure");
    expect(failureCount).toBe(1);

    await logs.locator('button[data-action="clear-search"]').click();
    await logs.locator('button[data-level="all"]').click();
    await expect(logs.locator(".refresh-status")).toHaveText("Synced: all");
    await logs.locator(".log-row[data-log-id='log-480']").click();
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-480");

    await logs.locator('button[data-action="refresh-now"]').click();
    await expect(logs.locator(".logs-screen")).toHaveAttribute("data-retained-count", "1480");
    await expect(logs.locator(".logs-screen")).toHaveAttribute("data-refresh-step-count", "1000");
    await expect(logs.locator("aside.drawer")).toHaveAttribute("data-selected-id", "log-480");
    await logs.locator('button[data-action="refresh-now"]').click();
    await expect(logs.locator(".logs-screen")).toHaveAttribute("data-retained-count", "2000");
    await expect(logs.locator(".logs-screen")).toHaveAttribute("data-refresh-step-count", "2000");
    await expect(logs.locator(".log-row").first()).toHaveAttribute("data-log-id", "log-2480");
    await expect(logs.locator("aside.drawer")).toHaveCount(0);
    await expect(logs.locator(".log-row")).toHaveCount(50);

    const lateRequest = page.waitForRequest((request) =>
      request.url().endsWith("/api/logs") && request.method() === "POST" &&
      request.postData()?.includes('"level":"info"') === true,
    );
    await logs.locator('button[data-level="info"]').click();
    await lateRequest;
    await topbar.locator('button[data-screen="home"]').click();
    await expect(root.locator("logs-screen")).toHaveCount(0);
    await delayedResponseFinished;
    await expect.poll(async () => page.evaluate(() => {
      const stats = (window as any).MochiLoader.debugStats();
      return `${stats.timers}:${stats.activeFetches}:${stats.pendingFetches}`;
    })).toBe("0:0:0");
    await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM theme storage reaches shell and overlays across reload and tabs", async ({ page, context }) => {
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));
  const second = await context.newPage();
  setupConsoleLogging(second);
  second.on("pageerror", (err) => errors.push(err.message));

  const surfaceOf = (locator: Locator) => locator.evaluate((element) => (
    getComputedStyle(element).getPropertyValue("--surface").trim()
  ));

  try {
    await page.goto(`${baseURL}/settings`);
    const root = page.locator("z-root");
    const shell = root.locator(".shell");
    await expect(root.locator("settings-screen h1")).toHaveText("Settings");
    await expect(shell).not.toHaveClass(/dark/);
    const lightSurface = await surfaceOf(shell);
    expect(lightSurface).not.toBe("");

    await root.locator("settings-screen").locator('button[data-action="dark"]').click();
    await expect(shell).toHaveClass(/dark/);
    const darkSurface = await surfaceOf(shell);
    expect(darkSurface).not.toBe(lightSurface);

    const modal = root.locator(".shell modal-container .modal");
    await root.locator("top-bar").locator('button[data-action="profile"]').click();
    await expect(modal).toBeVisible();
    expect(await surfaceOf(modal)).toBe(darkSurface);
    await root.locator("modal-container .modal-backdrop").click({ position: { x: 5, y: 5 } });
    await expect(modal).toHaveCount(0);

    await root.locator("top-bar").locator('button[data-screen="queues"]').click();
    const queues = root.locator("queues-screen");
    await expect(queues.locator("h1")).toHaveText("Queues");
    await queues.locator('button[data-action="refresh"]').click();
    const toast = root.locator(".shell toast-stack .toast").first();
    await expect(toast).toBeVisible();
    expect(await surfaceOf(toast)).toBe(darkSurface);

    await root.locator("top-bar").locator('button[data-screen="settings"]').click();
    await expect(root.locator("settings-screen h1")).toHaveText("Settings");
    await page.reload();
    await expect(root.locator(".shell")).toHaveClass(/dark/);
    await expect(root.locator("settings-screen h1")).toHaveText("Settings");

    await second.goto(`${baseURL}/settings`);
    const secondRoot = second.locator("z-root");
    const secondShell = secondRoot.locator(".shell");
    await expect(secondShell).toHaveClass(/dark/);

    await root.locator("settings-screen").locator('button[data-action="light"]').click();
    await expect(shell).not.toHaveClass(/dark/);
    await expect(secondShell).not.toHaveClass(/dark/);

    await secondRoot.locator("settings-screen").locator('button[data-action="dark"]').click();
    await expect(secondShell).toHaveClass(/dark/);
    await expect(shell).toHaveClass(/dark/);

    await page.evaluate(() => localStorage.setItem("cowboy_theme", "sepia"));
    await page.reload();
    await expect(root.locator(".shell")).not.toHaveClass(/dark/);
    await expect(root.locator(".shell")).toHaveAttribute("data-storage-error", "invalid");
    expect(errors).toEqual([]);
  } finally {
    await second.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM routing: a direct Costs URL loads only the Costs dependency closure", async ({ page }) => {
  setupConsoleLogging(page);
  const requested: string[] = [];
  page.on("request", (request) => requested.push(new URL(request.url()).pathname));
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/costs`);
    const root = page.locator("z-root");
    await expect(root.locator("costs-screen .summary.primary strong")).toHaveText("6.5M");
    await expect(root.locator("home-screen")).toHaveCount(0);
    await expect(root.locator("top-bar").locator('button[data-screen="costs"]')).toHaveClass(/active/);

    expect(requested.filter((url) => url.endsWith("/components/costs-screen.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/costs-screen.chi"))).toHaveLength(1);
    const otherScreens = [
      "home-screen", "events-screen", "queues-screen", "logs-screen",
      "limits-screen", "settings-screen", "canvas-screen", "not-found-screen",
    ];
    otherScreens.forEach((tag) => {
      expect(requested.filter((url) => url.endsWith(`/components/${tag}.json`))).toHaveLength(0);
      expect(requested.filter((url) => url.endsWith(`/components/${tag}.chi`))).toHaveLength(0);
    });
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM routing: back and forward render the route-owned screens", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/`);
    const root = page.locator("z-root");
    await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");

    const topbar = root.locator("top-bar");
    await topbar.locator('button[data-screen="costs"]').click();
    await expect(root.locator("costs-screen .summary.primary strong")).toHaveText("6.5M");
    expect(new URL(page.url()).pathname).toBe("/costs");

    await topbar.locator('button[data-screen="logs"]').click();
    await expect(root.locator("logs-screen .log-row")).toHaveCount(50);
    expect(new URL(page.url()).pathname).toBe("/logs");

    await page.goBack();
    await expect(root.locator("costs-screen .summary.primary strong")).toHaveText("6.5M");
    expect(new URL(page.url()).pathname).toBe("/costs");
    await expect(topbar.locator('button[data-screen="costs"]')).toHaveClass(/active/);

    await page.goForward();
    await expect(root.locator("logs-screen .log-row")).toHaveCount(50);
    expect(new URL(page.url()).pathname).toBe("/logs");
    await expect(topbar.locator('button[data-screen="logs"]')).toHaveClass(/active/);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("Costs stays lazy on Home and retains one copy of its dependency closure", async ({ page }) => {
  setupConsoleLogging(page);
  const requested: string[] = [];
  page.on("request", (request) => requested.push(new URL(request.url()).pathname));
  const manifest = readManifest(frontendDistDir);
  const costTags = ["costs-screen", "costs-summary", "costs-daily-chart", "costs-model-table"];
  const costResources = new Set<string>();
  const initialStyles = new Set<string>();
  const initialCss = ["z-root", "top-bar", "home-screen", "toast-stack", "modal-container"]
    .map((tag) => readComponentDescriptor(frontendDistDir, manifest, tag).css || "")
    .join("\n");
  const costCss = costTags.map((tag) => {
    const descriptor = readComponentDescriptor(frontendDistDir, manifest, tag);
    (descriptor.style_resources || [])
      .forEach((id: string) => initialStyles.add(id));
    return descriptor.css || "";
  });
  costTags.forEach((tag) => {
    const descriptor = readComponentDescriptor(frontendDistDir, manifest, tag);
    (descriptor.style_resources || []).forEach((id: string) => {
      if (!initialStyles.has(id)) costResources.add(manifest.resources[id].file);
    });
  });
  expect(costCss.join("\n")).toContain(".summary-grid");
  expect(costCss.join("\n")).toContain(".chart");
  expect(initialCss).not.toContain(".summary-grid");
  expect(initialCss).not.toContain(".model-panel");
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/`);
    await expect(page.locator("z-root home-screen h1")).toHaveText("Keep the herd moving.");
    expect(requested.some((url) => url.endsWith("/mochi-format.js"))).toBe(false);
    costTags.forEach((tag) => {
      expect(requested.some((url) => url.endsWith(`/components/${tag}.json`))).toBe(false);
      expect(requested.some((url) => url.endsWith(`/components/${tag}.chi`))).toBe(false);
    });
    costResources.forEach((file) => {
      expect(requested.some((url) => url.endsWith(`/${file}`))).toBe(false);
    });

    await page.locator("z-root top-bar button[data-screen='costs']").click();
    await expect(page.locator("z-root costs-screen costs-summary .summary.primary strong")).toHaveText("6.5M");
    costTags.forEach((tag) => {
      expect(requested.filter((url) => url.endsWith(`/components/${tag}.json`))).toHaveLength(1);
      expect(requested.filter((url) => url.endsWith(`/components/${tag}.chi`))).toHaveLength(1);
    });
    costResources.forEach((file) => {
      expect(requested.filter((url) => url.endsWith(`/${file}`))).toHaveLength(1);
    });
    expect(requested.filter((url) => url.endsWith("/mochi-format.js"))).toHaveLength(1);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("Costs navigation and filter loops keep screen registrations bounded", async ({ page }) => {
  test.setTimeout(180_000);
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__costsRuntimeErrors = [];
    document.addEventListener("mochi:error", (event: any) => {
      (window as any).__costsRuntimeErrors.push(event.detail || { message: "Mochi runtime error" });
    });
  });
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/`);
    const root = page.locator("z-root");
    const topbar = root.locator("top-bar");
    await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");
    const homeBaseline = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    let costsBaseline: Record<string, number> | null = null;
    const samples: Array<{ screen: string; stats: Record<string, number> }> = [];

    for (let round = 0; round < 200; round += 1) {
      await topbar.locator('button[data-screen="costs"]').click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "6469040");
      await root.locator("costs-screen button[data-period='30']").click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "27046540");
      await root.locator("costs-screen button[data-harness='Codex']").click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "8896860");
      await root.locator("costs-screen button[data-harness='Antigravity']").click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "8197820");
      await root.locator("costs-screen button[data-harness='Ollama']").click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "9951860");
      await root.locator("costs-screen button[data-harness='All']").click();
      await root.locator("costs-screen button[data-period='7']").click();
      await expect(root.locator("costs-screen costs-summary .summary-grid")).toHaveAttribute("data-raw-total", "6469040");
      const stats = await page.evaluate(() => (window as any).MochiLoader.debugStats());
      if (!costsBaseline) costsBaseline = stats;
      samples.push({ screen: "costs", stats });

      await topbar.locator('button[data-screen="home"]').click();
      await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");
      samples.push({ screen: "home", stats: await page.evaluate(() => (window as any).MochiLoader.debugStats()) });
    }

    const mismatches = samples.filter(({ screen, stats }) => {
      const baseline = screen === "home" ? homeBaseline : costsBaseline;
      return !baseline || ["components", "bindings", "elements", "timers"].some((key) => stats[key] !== baseline[key]);
    });
    expect(mismatches.slice(0, 2)).toEqual([]);
    expect(await page.evaluate(() => (window as any).__costsRuntimeErrors)).toEqual([]);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM routing: encoded params and query values arrive as Ruby strings", async ({ page }) => {
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/logs/hello%20world?level=warn`);
    const root = page.locator("z-root");
    await expect(root.locator(".shell")).toHaveAttribute("data-log-id", "hello world");
    await expect(root.locator("logs-screen .route-context")).toHaveText("Focused: hello world");
    await expect(root.locator('logs-screen button[data-level="warn"]')).toHaveClass(/active/);
    await expect(root.locator("logs-screen .result-count")).toContainText("72 events");
    await expect(root.locator("logs-screen .log-row")).toHaveCount(50);
    expect(new URL(page.url()).pathname).toBe("/logs/hello%20world");
    expect(new URL(page.url()).search).toBe("?level=warn");
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM routing: unknown paths render a deterministic not-found screen", async ({ page }) => {
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/missing/screen`);
    const root = page.locator("z-root");
    await expect(root.locator("not-found-screen h1")).toHaveText("Route not found");
    await expect(root.locator("home-screen")).toHaveCount(0);
    await root.locator("not-found-screen .home-button").click();
    await expect(root.locator("home-screen h1")).toHaveText("Keep the herd moving.");
    expect(new URL(page.url()).pathname).toBe("/");
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("GVM routing: rapid navigation never mounts an obsolete delayed screen", async ({ page }) => {
  setupConsoleLogging(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  let delayed = false;
  await page.route("**/components/costs-screen.chi", async (route) => {
    if (!delayed) {
      delayed = true;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    await route.continue();
  });
  const { server, baseURL } = await startStaticServer(frontendDistDir, { spaFallback: true });
  try {
    await page.goto(`${baseURL}/`);
    const root = page.locator("z-root");
    const topbar = root.locator("top-bar");
    const costsClass = page.waitForRequest((request) => request.url().endsWith("/components/costs-screen.chi"));
    await topbar.locator('button[data-screen="costs"]').click();
    await costsClass;
    await topbar.locator('button[data-screen="logs"]').click();
    await expect(root.locator("logs-screen .log-row")).toHaveCount(50, { timeout: 15_000 });
    await page.waitForTimeout(700);
    await expect(root.locator("costs-screen")).toHaveCount(0);
    await expect(root.locator("logs-screen .log-row")).toHaveCount(50);
    expect(new URL(page.url()).pathname).toBe("/logs");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("modal keeps backdrop-only close, focus containment, and opener restore", async ({ page }) => {
  setupConsoleLogging(page);
  const { server, baseURL } = await startStaticServer(frontendDistDir);
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

test("GVM numbers keep integer and float semantics across props, events, and bindings", async ({ page }) => {
  setupConsoleLogging(page, { expectedMochiErrors: true });
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-numbers-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "NumericChild.rb"), `
class NumericChild
  @tag_name = "numeric-child"
  prop :total, Integer, default: 0
  prop :ratio, Float, default: 0.0
  event :measured, total: Integer, ratio: Float

  def html
    %Q{
      <span class="child-total">{@total}</span>
      <span class="child-ratio">{@ratio}</span>
      <div class="child-bar" style="height: {@ratio * 100}px"></div>
      <button class="send" onclick="{send_measured}">Send</button>
    }
  end

  def send_measured
    emit :measured, total: @total, ratio: @ratio
  end
end
`);

  fs.writeFileSync(path.join(projectDir, "lib", "NumericHost.rb"), `
class NumericHost
  @tag_name = "numeric-host"
  @one
  @two
  @ratio
  @total
  @int_half
  @float_half
  @rate
  @items
  @received_total
  @received_ratio
  @max
  @minimum

  def initialize
    @one = 1
    @two = 2
    @ratio = 0.25
    @total = 9007199254740993
    @int_half = @one / @two
    @float_half = 1.0 / 2
    @rate = 3000000 * 1500
    @items = [1.25, 2.5, 3.75]
    @received_total = 0
    @received_ratio = 0.0
    @max = 9223372036854775807
    @minimum = -9223372036854775808
  end

  def html
    %Q{
      <span class="int-half">{@int_half}</span>
      <span class="float-half">{@float_half}</span>
      <span class="rate">{@rate}</span>
      <span class="large">{@total}</span>
      <span class="large-sum">{@total + 2}</span>
      <span class="minimum">{@minimum}</span>
      <div class="chart" style="height: {@ratio * 100}px"></div>
      <div class="points">
        {each @items as item}
          <div class="point" style="height: {item * 10}px"><span class="point-value">{item}</span></div>
        {end}
      </div>
      <numeric-child
        class="numeric-child"
        total="{@total}"
        ratio="{@ratio}"
        on:measured="{measured($event)}"
      ></numeric-child>
      <span class="received-total">{@received_total}</span>
      <span class="received-ratio">{@received_ratio}</span>
      <button class="change" onclick="{change_numbers}">Change</button>
      <button class="overflow" onclick="{force_overflow}">Overflow</button>
    }
  end

  def measured(payload)
    @received_total = payload[:total]
    @received_ratio = payload[:ratio]
  end

  def change_numbers
    @ratio = 0.5
    @items = [0.5, 1.5, 2.5]
  end

  def force_overflow
    @total = @max + 1
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
    <numeric-host></numeric-host>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const numericManifest = JSON.parse(
    fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"),
  );
  expect(numericManifest.schema_version).toBe(2);
  expect(numericManifest.prelude).toBeUndefined();
  expect(numericManifest.format_host).toBeUndefined();
  expect(
    Object.keys(numericManifest.packages).some((id) => id.startsWith("capability:")),
  ).toBe(false);

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const host = page.locator("numeric-host");
    const child = host.locator("numeric-child.numeric-child");

    await expect(host.locator("span.int-half")).toHaveText("0");
    await expect(host.locator("span.float-half")).toHaveText("0.5");
    await expect(host.locator("span.rate")).toHaveText("4500000000");
    await expect(host.locator("span.large")).toHaveText("9007199254740993");
    await expect(host.locator("span.large-sum")).toHaveText("9007199254740995");
    await expect(host.locator("span.minimum")).toHaveText("-9223372036854775808");
    await expect(host.locator("div.chart")).toHaveAttribute("style", /height:\s*25(?:\.0)?px/);

    await expect(host.locator("div.point")).toHaveCount(3);
    await expect(host.locator("span.point-value")).toHaveText(["1.25", "2.5", "3.75"]);
    await expect(host.locator("div.point").nth(0)).toHaveAttribute("style", /height:\s*12\.5px/);
    await expect(host.locator("div.point").nth(2)).toHaveAttribute("style", /height:\s*37\.5px/);

    await expect(child.locator("span.child-total")).toHaveText("9007199254740993");
    await expect(child.locator("span.child-ratio")).toHaveText("0.25");
    await expect(child.locator("div.child-bar")).toHaveAttribute("style", /height:\s*25(?:\.0)?px/);

    await child.locator("button.send").click();
    await expect(host.locator("span.received-total")).toHaveText("9007199254740993");
    await expect(host.locator("span.received-ratio")).toHaveText("0.25");

    await host.locator("button.change").click();
    await expect(host.locator("div.chart")).toHaveAttribute("style", /height:\s*50(?:\.0)?px/);
    await expect(host.locator("span.point-value")).toHaveText(["0.5", "1.5", "2.5"]);
    await expect(host.locator("div.point").nth(0)).toHaveAttribute("style", /height:\s*5(?:\.0)?px/);
    await expect(host.locator("div.point").nth(2)).toHaveAttribute("style", /height:\s*25(?:\.0)?px/);
    await expect(child.locator("span.child-ratio")).toHaveText("0.5");
    await expect(child.locator("div.child-bar")).toHaveAttribute("style", /height:\s*50(?:\.0)?px/);

    await child.locator("button.send").click();
    await expect(host.locator("span.received-total")).toHaveText("9007199254740993");
    await expect(host.locator("span.received-ratio")).toHaveText("0.5");

    await page.evaluate(() => {
      (window as any).__mochiNumericErrors = [];
      document.addEventListener("mochi:error", (event: any) => {
        (window as any).__mochiNumericErrors.push(event.detail);
      });
    });
    await host.locator("button.overflow").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiNumericErrors.length,
    )).toBe(1);
    const numericError = await page.evaluate(() => (window as any).__mochiNumericErrors[0]);
    expect(numericError.phase).toBe("event");
    expect(numericError.message).toMatch(/integer overflow/);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM money helpers keep exact minor-unit totals and named rounding", async ({ page }) => {
  setupConsoleLogging(page, { expectedMochiErrors: true });
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-money-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  const roundVectors = [
    { name: "positive_half", numerator: 1, denominator: 2 },
    { name: "negative_half", numerator: -1, denominator: 2 },
    { name: "positive_odd_half", numerator: 3, denominator: 2 },
    { name: "negative_odd_half", numerator: -3, denominator: 2 },
    { name: "positive_even_half", numerator: 5, denominator: 2 },
    { name: "negative_even_half", numerator: -5, denominator: 2 },
    { name: "negative_denominator", numerator: 3, denominator: -2 },
  ];
  const rationalOracle = JSON.parse(execFileSync("ruby", ["-rjson", "-e", `
    vectors = JSON.parse(STDIN.read)
    puts vectors.map { |vector|
      value = Rational(vector["numerator"], vector["denominator"])
      {
        "name" => vector["name"],
        "exact" => "#{value.numerator}/#{value.denominator}",
        "half_up" => value.round(half: :up),
        "half_down" => value.round(half: :down),
        "half_even" => value.round(half: :even),
        "floor" => value.floor,
        "ceil" => value.ceil,
        "truncate" => value.to_i
      }
    }.to_json
  `], { input: JSON.stringify(roundVectors), encoding: "utf8" }));
  const adjustmentOracle = execFileSync("ruby", ["-e", `
    ledger = Rational(0, 1)
    ledger += Rational(3, 5)
    ledger += Rational(-4, 5)
    ledger *= Rational(3, 2)
    puts "#{ledger.numerator}/#{ledger.denominator}|#{ledger.round(half: :up)}"
  `], { encoding: "utf8" }).trim();
  const roundVectorRuby = roundVectors.map((vector) => `
    @${vector.name}_ledger = MochiMoney.amount(${vector.numerator}, ${vector.denominator})
    @${vector.name}_rounds = [
      MochiMoney.exact(@${vector.name}_ledger),
      MochiMoney.round_half_up(@${vector.name}_ledger).to_s,
      MochiMoney.round_half_down(@${vector.name}_ledger).to_s,
      MochiMoney.round_half_even(@${vector.name}_ledger).to_s,
      MochiMoney.round_floor(@${vector.name}_ledger).to_s,
      MochiMoney.round_ceil(@${vector.name}_ledger).to_s,
      MochiMoney.round_truncate(@${vector.name}_ledger).to_s
    ].join("|")
  `).join("\n");
  const roundVectorHTML = roundVectors.map((vector) =>
    `<span class="vector-${vector.name}">{@${vector.name}_rounds}</span>`
  ).join("\n");

  fs.writeFileSync(path.join(projectDir, "lib", "MoneyLedger.rb"), `
class MoneyLedger
  @tag_name = "money-ledger"
  @rows
  @model_a
  @model_b
  @harness
  @total
  @component
  @subcent_a
  @subcent_b
  @subcent_c
  @subcent
  @negative
  @max
  @min
  @overflow
  @atomic_add
  @atomic_apply
  @atomic_add_exact
  @atomic_apply_exact
  @adjusted
  @adjusted_exact
  @adjusted_rounded
  @model_a_exact
  @model_a_cents
  @model_a_label
  @model_b_exact
  @model_b_cents
  @model_b_label
  @harness_exact
  @harness_cents
  @harness_label
  @total_exact
  @total_cents
  @total_label
  @component_exact
  @component_cents
  @component_label
  @display_sum_cents
  @display_difference
  @subcent_exact
  @subcent_cents
  @subcent_lines_cents
  @negative_exact
  @negative_half_up
  @negative_half_down
  @negative_half_even
  @negative_floor
  @negative_ceil
  @negative_truncate
  @negative_label
  @max_exact
  @max_cents
  @min_exact
  @min_cents
  ${roundVectors.map((vector) => `@${vector.name}_ledger\n  @${vector.name}_rounds`).join("\n  ")}

  def money(cents)
    sign = ""
    value = cents
    if cents < 0
      sign = "-"
      value = -cents
    end
    whole = value / 100
    remainder = value % 100
    fraction = remainder.to_s
    if remainder < 10
      fraction = "0" + fraction
    end
    return sign + "$" + whole.to_s + "." + fraction
  end

  def refresh
    @model_a_exact = MochiMoney.exact(@model_a)
    @model_a_cents = MochiMoney.round_half_up(@model_a)
    @model_a_label = money(@model_a_cents)
    @model_b_exact = MochiMoney.exact(@model_b)
    @model_b_cents = MochiMoney.round_half_up(@model_b)
    @model_b_label = money(@model_b_cents)
    @harness_exact = MochiMoney.exact(@harness)
    @harness_cents = MochiMoney.round_half_up(@harness)
    @harness_label = money(@harness_cents)
    @total_exact = MochiMoney.exact(@total)
    @total_cents = MochiMoney.round_half_up(@total)
    @total_label = money(@total_cents)
    @component_exact = MochiMoney.exact(@component)
    @component_cents = MochiMoney.round_half_up(@component)
    @component_label = money(@component_cents)
    @display_sum_cents = @model_a_cents + @model_b_cents
    @display_difference = @display_sum_cents - @total_cents
    @subcent_exact = MochiMoney.exact(@subcent)
    @subcent_cents = MochiMoney.round_half_up(@subcent)
    @subcent_lines_cents = MochiMoney.round_half_up(@subcent_a) + MochiMoney.round_half_up(@subcent_b) + MochiMoney.round_half_up(@subcent_c)
    @negative_exact = MochiMoney.exact(@negative)
    @negative_half_up = MochiMoney.round_half_up(@negative)
    @negative_half_down = MochiMoney.round_half_down(@negative)
    @negative_half_even = MochiMoney.round_half_even(@negative)
    @negative_floor = MochiMoney.round_floor(@negative)
    @negative_ceil = MochiMoney.round_ceil(@negative)
    @negative_truncate = MochiMoney.round_truncate(@negative)
    @negative_label = money(@negative_half_up)
    @max_exact = MochiMoney.exact(@max)
    @max_cents = MochiMoney.round_half_up(@max)
    @min_exact = MochiMoney.exact(@min)
    @min_cents = MochiMoney.round_half_up(@min)
    ${roundVectorRuby}
  end

  def initialize
    @rows = [
      {"model" => "claude-sonnet", "input" => 202000, "cached" => 0, "output" => 0, "rin" => 300, "rcache" => 30, "rout" => 1500},
      {"model" => "gemini-pro", "input" => 1000, "cached" => 0, "output" => 0, "rin" => 200, "rcache" => 20, "rout" => 1000},
      {"model" => "gemini-pro", "input" => 0, "cached" => 10000, "output" => 0, "rin" => 200, "rcache" => 20, "rout" => 1000},
      {"model" => "gemini-pro", "input" => 0, "cached" => 0, "output" => 200, "rin" => 200, "rcache" => 20, "rout" => 1000}
    ]
    @model_a = MochiMoney.ledger
    @model_b = MochiMoney.ledger
    @harness = MochiMoney.ledger
    @total = MochiMoney.ledger
    @rows.each do |row|
      charge = row["input"] * row["rin"] + row["cached"] * row["rcache"] + row["output"] * row["rout"]
      if row["model"] == "claude-sonnet"
        MochiMoney.add_ratio(@model_a, charge, 1000000)
      else
        MochiMoney.add_ratio(@model_b, charge, 1000000)
      end
      MochiMoney.add_ratio(@harness, charge, 1000000)
      MochiMoney.add_ratio(@total, charge, 1000000)
    end
    @component = MochiMoney.ledger
    MochiMoney.merge(@component, @total)
    MochiMoney.apply_ratio(@component, 22, 100)

    @subcent_a = MochiMoney.amount(2, 5)
    @subcent_b = MochiMoney.amount(2, 5)
    @subcent_c = MochiMoney.amount(2, 5)
    @subcent = MochiMoney.ledger
    MochiMoney.merge(@subcent, @subcent_a)
    MochiMoney.merge(@subcent, @subcent_b)
    MochiMoney.merge(@subcent, @subcent_c)
    @negative = MochiMoney.amount(-1, 2)
    @max = MochiMoney.minor(9223372036854775807)
    @min = MochiMoney.minor(-9223372036854775808)
    @overflow = MochiMoney.minor(9223372036854775807)
    @atomic_add = MochiMoney.ledger
    @atomic_apply = MochiMoney.ledger
    @atomic_add_exact = MochiMoney.exact(@atomic_add)
    @atomic_apply_exact = MochiMoney.exact(@atomic_apply)
    @adjusted = MochiMoney.ledger
    MochiMoney.add_ratio(@adjusted, 3, 5)
    MochiMoney.merge(@adjusted, MochiMoney.amount(-4, 5))
    MochiMoney.apply_ratio(@adjusted, 3, 2)
    @adjusted_exact = MochiMoney.exact(@adjusted)
    @adjusted_rounded = MochiMoney.round_half_up(@adjusted)

    refresh
  end

  def force_overflow
    MochiMoney.add_minor(@overflow, 1)
  end

  def force_zero_denominator
    MochiMoney.amount(1, 0)
  end

  def force_float_input
    MochiMoney.add_ratio(@atomic_add, 1.0, 2)
  end

  def force_string_input
    MochiMoney.add_ratio(@atomic_add, "1", 2)
  end

  def force_normalize_overflow
    MochiMoney.add_ratio(@atomic_add, 1, -9223372036854775808)
  end

  def force_apply_normalize_overflow
    MochiMoney.apply_ratio(@atomic_apply, 1, -9223372036854775808)
  end

  def inspect_failed_ledgers
    @atomic_add_exact = MochiMoney.exact(@atomic_add)
    @atomic_apply_exact = MochiMoney.exact(@atomic_apply)
  end

  def html
    %Q{
      <span class="model-a-exact">{@model_a_exact}</span>
      <span class="model-a-cents">{@model_a_cents}</span>
      <span class="model-a-label">{@model_a_label}</span>
      <span class="model-b-exact">{@model_b_exact}</span>
      <span class="model-b-cents">{@model_b_cents}</span>
      <span class="model-b-label">{@model_b_label}</span>
      <span class="harness-exact">{@harness_exact}</span>
      <span class="harness-cents">{@harness_cents}</span>
      <span class="harness-label">{@harness_label}</span>
      <span class="total-exact">{@total_exact}</span>
      <span class="total-cents">{@total_cents}</span>
      <span class="total-label">{@total_label}</span>
      <span class="component-exact">{@component_exact}</span>
      <span class="component-cents">{@component_cents}</span>
      <span class="component-label">{@component_label}</span>
      <span class="display-sum-cents">{@display_sum_cents}</span>
      <span class="display-difference">{@display_difference}</span>
      <span class="subcent-exact">{@subcent_exact}</span>
      <span class="subcent-cents">{@subcent_cents}</span>
      <span class="subcent-lines-cents">{@subcent_lines_cents}</span>
      <span class="negative-exact">{@negative_exact}</span>
      <span class="negative-half-up">{@negative_half_up}</span>
      <span class="negative-half-down">{@negative_half_down}</span>
      <span class="negative-half-even">{@negative_half_even}</span>
      <span class="negative-floor">{@negative_floor}</span>
      <span class="negative-ceil">{@negative_ceil}</span>
      <span class="negative-truncate">{@negative_truncate}</span>
      <span class="negative-label">{@negative_label}</span>
      <span class="max-exact">{@max_exact}</span>
      <span class="max-cents">{@max_cents}</span>
      <span class="min-exact">{@min_exact}</span>
      <span class="min-cents">{@min_cents}</span>
      <span class="atomic-add-exact">{@atomic_add_exact}</span>
      <span class="atomic-apply-exact">{@atomic_apply_exact}</span>
      <span class="adjusted-exact">{@adjusted_exact}</span>
      <span class="adjusted-rounded">{@adjusted_rounded}</span>
      ${roundVectorHTML}
      <button class="overflow" onclick="{force_overflow}">Overflow</button>
      <button class="zero-denominator" onclick="{force_zero_denominator}">Zero denominator</button>
      <button class="float-input" onclick="{force_float_input}">Float input</button>
      <button class="string-input" onclick="{force_string_input}">String input</button>
      <button class="normalize-overflow" onclick="{force_normalize_overflow}">Normalize overflow</button>
      <button class="apply-normalize-overflow" onclick="{force_apply_normalize_overflow}">Apply normalize overflow</button>
      <button class="inspect-failed-ledgers" onclick="{inspect_failed_ledgers}">Inspect failed ledgers</button>
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
    <money-ledger></money-ledger>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const moneyManifest = JSON.parse(
    fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"),
  );
  expect(moneyManifest.schema_version).toBe(2);
  expect(moneyManifest.prelude).toBeUndefined();
  expect(moneyManifest.format_host).toBeUndefined();
  expect(readComponentDescriptor(bundleDir, moneyManifest, "money-ledger").formatting).toBeUndefined();
  const moneyPackages = Object.entries(moneyManifest.packages).map(([id, pkg]: [string, any]) => ({
    id,
    ...pkg,
  }));
  expect(
    moneyPackages.some((pkg) => (pkg.exports || []).includes("MochiMoney")),
  ).toBe(true);
  expect(moneyPackages.some((pkg) => pkg.id.startsWith("capability:"))).toBe(false);

  const unusedProjectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-no-money-"));
  const unusedBundleDir = path.join(unusedProjectDir, "bundle");
  fs.mkdirSync(path.join(unusedProjectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(unusedProjectDir, "lib", "PlainPanel.rb"), `
class PlainPanel
  @tag_name = "plain-panel"
  def html
    %Q{<p>plain application</p>}
  end
end
`);
  fs.writeFileSync(path.join(unusedProjectDir, "index.html"), `<!doctype html>
<html><body><plain-panel></plain-panel></body></html>`);
  try {
    execFileSync(compilerBinary, ["-i", unusedProjectDir, "-o", unusedBundleDir], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: "pipe",
    });
    const unusedManifest = JSON.parse(
      fs.readFileSync(path.join(unusedBundleDir, "mochi-manifest.json"), "utf8"),
    );
    const unusedPackages = Object.values(unusedManifest.packages) as any[];
    expect(unusedPackages.some((pkg) => (pkg.exports || []).includes("MochiMoney"))).toBe(false);
  } finally {
    fs.rmSync(unusedProjectDir, { recursive: true, force: true });
  }

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const host = page.locator("money-ledger");

    await expect(host.locator("span.model-a-exact")).toHaveText("303/5");
    await expect(host.locator("span.model-b-exact")).toHaveText("3/5");
    await expect(host.locator("span.harness-exact")).toHaveText("306/5");
    await expect(host.locator("span.total-exact")).toHaveText("306/5");
    await expect(host.locator("span.component-exact")).toHaveText("1683/125");
    await expect(host.locator("span.subcent-exact")).toHaveText("6/5");
    await expect(host.locator("span.negative-exact")).toHaveText("-1/2");
    await expect(host.locator("span.max-exact")).toHaveText("9223372036854775807/1");
    await expect(host.locator("span.min-exact")).toHaveText("-9223372036854775808/1");
    const [adjustedExact, adjustedRounded] = adjustmentOracle.split("|");
    await expect(host.locator("span.adjusted-exact")).toHaveText(adjustedExact);
    await expect(host.locator("span.adjusted-rounded")).toHaveText(adjustedRounded);

    for (const vector of rationalOracle) {
      await expect(host.locator(`.vector-${vector.name}`)).toHaveText([
        vector.exact,
        vector.half_up,
        vector.half_down,
        vector.half_even,
        vector.floor,
        vector.ceil,
        vector.truncate,
      ].join("|"));
    }

    await expect(host.locator("span.model-a-cents")).toHaveText("61");
    await expect(host.locator("span.model-b-cents")).toHaveText("1");
    await expect(host.locator("span.harness-cents")).toHaveText("61");
    await expect(host.locator("span.total-cents")).toHaveText("61");
    await expect(host.locator("span.component-cents")).toHaveText("13");
    await expect(host.locator("span.display-sum-cents")).toHaveText("62");
    await expect(host.locator("span.display-difference")).toHaveText("1");
    await expect(host.locator("span.subcent-cents")).toHaveText("1");
    await expect(host.locator("span.subcent-lines-cents")).toHaveText("0");
    await expect(host.locator("span.max-cents")).toHaveText("9223372036854775807");
    await expect(host.locator("span.min-cents")).toHaveText("-9223372036854775808");

    await expect(host.locator("span.model-a-label")).toHaveText("$0.61");
    await expect(host.locator("span.model-b-label")).toHaveText("$0.01");
    await expect(host.locator("span.harness-label")).toHaveText("$0.61");
    await expect(host.locator("span.total-label")).toHaveText("$0.61");
    await expect(host.locator("span.component-label")).toHaveText("$0.13");

    await expect(host.locator("span.negative-half-up")).toHaveText("-1");
    await expect(host.locator("span.negative-half-down")).toHaveText("0");
    await expect(host.locator("span.negative-half-even")).toHaveText("0");
    await expect(host.locator("span.negative-floor")).toHaveText("-1");
    await expect(host.locator("span.negative-ceil")).toHaveText("0");
    await expect(host.locator("span.negative-truncate")).toHaveText("0");
    await expect(host.locator("span.negative-label")).toHaveText("-$0.01");

    await page.evaluate(() => {
      (window as any).__mochiMoneyErrors = [];
      document.addEventListener("mochi:error", (event: any) => {
        (window as any).__mochiMoneyErrors.push(event.detail);
      });
    });
    await host.locator("button.zero-denominator").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(1);
    const zeroDenominatorError = await page.evaluate(() => (window as any).__mochiMoneyErrors[0]);
    expect(zeroDenominatorError.phase).toBe("event");
    expect(zeroDenominatorError.message).toMatch(/division by zero/);

    await host.locator("button.float-input").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(2);
    const floatInputError = await page.evaluate(() => (window as any).__mochiMoneyErrors[1]);
    expect(floatInputError.phase).toBe("event");
    expect(floatInputError.message).toMatch(/MochiMoney#__require_integer: unknown method at lib\/MoneyLedger\.rb:/);
    await host.locator("button.string-input").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(3);
    const stringInputError = await page.evaluate(() => (window as any).__mochiMoneyErrors[2]);
    expect(stringInputError.phase).toBe("event");
    expect(stringInputError.message).toMatch(/MochiMoney#__require_integer: unknown method at lib\/MoneyLedger\.rb:/);
    await host.locator("button.normalize-overflow").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(4);
    const normalizeError = await page.evaluate(() => (window as any).__mochiMoneyErrors[3]);
    expect(normalizeError.message).toMatch(/integer overflow at lib\/MoneyLedger\.rb:/);
    await host.locator("button.apply-normalize-overflow").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(5);
    const applyNormalizeError = await page.evaluate(() => (window as any).__mochiMoneyErrors[4]);
    expect(applyNormalizeError.message).toMatch(/integer overflow at lib\/MoneyLedger\.rb:/);
    await host.locator("button.inspect-failed-ledgers").click();
    await expect(host.locator("span.atomic-add-exact")).toHaveText("0/1");
    await expect(host.locator("span.atomic-apply-exact")).toHaveText("0/1");

    await host.locator("button.overflow").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiMoneyErrors.length,
    )).toBe(6);
    const moneyError = await page.evaluate(() => (window as any).__mochiMoneyErrors[5]);
    expect(moneyError.phase).toBe("event");
    expect(moneyError.message).toMatch(/integer overflow/);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM formatting helpers use browser Intl from initialize, bindings, and each rows", async ({ page }) => {
  setupConsoleLogging(page, { expectedMochiErrors: true });
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-format-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "FormatScreen.rb"), `
class FormatScreen
  @tag_name = "format-screen"
  @rows
  @decimal
  @currency
  @compact
  @percent
  @date_short
  @date_zone
  @exact
  @money

  def initialize
    @rows = [
      {"name" => "alpha", "value" => 1234.5},
      {"name" => "beta", "value" => 9876.5}
    ]
    @decimal = MochiFormat.decimal(1234567.89, "en-US", {"maximum_fraction_digits" => 2})
    @currency = MochiFormat.currency(123456, "USD", "en-US", 2)
    @compact = MochiFormat.compact(1234567, "en-US")
    @percent = MochiFormat.percent(0.42, "en-US")
    @date_short = MochiFormat.date("2026-10-11", "en-US", "UTC", {"month" => "short", "day" => "numeric"})
    @date_zone = MochiFormat.date("2026-11-09T23:30:00Z", "en-US", "Asia/Tokyo", {"date_style" => "medium", "time_style" => "short"})
    @exact = MochiFormat.decimal(9223372036854775807, "en-US")
    cost = MochiMoney.ledger
    MochiMoney.add_ratio(cost, 202_000 * 300, 1_000_000)
    @money = MochiFormat.currency(MochiMoney.round_half_up(cost), "USD", "en-US", 2)
  end

  def row_label(value)
    MochiFormat.decimal(value, "de-DE")
  end

  def bad_locale
    MochiFormat.decimal(1, "en_US")
  end

  def html
    %Q{
      <p class="decimal">{@decimal}</p>
      <p class="currency">{@currency}</p>
      <p class="compact">{@compact}</p>
      <p class="percent">{@percent}</p>
      <p class="date-short">{@date_short}</p>
      <p class="date-zone">{@date_zone}</p>
      <p class="exact">{@exact}</p>
      <p class="money">{@money}</p>
      <p class="binding">{MochiFormat.compact(1234567, "en-US")}</p>
      <ul class="rows">
        {each @rows as row}
          <li class="row">{row_label(row["value"])}</li>
        {end}
      </ul>
      <button class="bad" onclick="{bad_locale}">Bad locale</button>
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
    <format-screen></format-screen>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const formatManifest = JSON.parse(
    fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"),
  );
  expect(formatManifest.schema_version).toBe(2);
  expect(formatManifest.prelude).toBeUndefined();
  expect(formatManifest.format_host).toBe("mochi-format.js");
  expect(formatManifest.capabilities.formatting).toMatchObject({
    version: 1,
    host: "mochi-format.js",
    operations: { format: "sync" },
  });
  const formatDescriptor = readComponentDescriptor(bundleDir, formatManifest, "format-screen");
  expect(formatDescriptor.formatting).toBe(true);
  expect(formatDescriptor.capabilities).toContain("formatting");
  expect(fs.existsSync(path.join(bundleDir, "mochi-format.js"))).toBe(true);

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));

  const { server, baseURL } = await startStaticServer(bundleDir);
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const host = page.locator("format-screen");

    await expect(host.locator("p.decimal")).toHaveText("1,234,567.89");
    await expect(host.locator("p.currency")).toHaveText("$1,234.56");
    await expect(host.locator("p.compact")).toHaveText("1.2M");
    await expect(host.locator("p.percent")).toHaveText("42%");
    await expect(host.locator("p.date-short")).toHaveText("Oct 11");
    await expect(host.locator("p.date-zone")).toHaveText("Nov 10, 2026, 8:30 AM");
    await expect(host.locator("p.exact")).toHaveText("9,223,372,036,854,775,807");
    await expect(host.locator("p.money")).toHaveText("$0.61");
    await expect(host.locator("p.binding")).toHaveText("1.2M");
    await expect(host.locator("li.row")).toHaveCount(2);
    await expect(host.locator("li.row").nth(0)).toHaveText("1.234,5");
    await expect(host.locator("li.row").nth(1)).toHaveText("9.876,5");

    const formatRequests = requested.filter((url) => url.endsWith("/mochi-format.js"));
    expect(formatRequests).toHaveLength(1);

    await page.evaluate(() => {
      (window as any).__mochiFormatErrors = [];
      document.addEventListener("mochi:error", (event: any) => {
        (window as any).__mochiFormatErrors.push(event.detail);
      });
    });
    await host.locator("button.bad").click();
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiFormatErrors.length,
    )).toBe(1);
    const formatError = await page.evaluate(() => (window as any).__mochiFormatErrors[0]);
    expect(formatError.phase).toBe("event");
    expect(formatError.message).toMatch(/invalid locale/);
    expect(formatError.message).toMatch(/en_US/);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM formatting host loads only when a formatting component mounts", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-format-lazy-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "PlainPanel.rb"), `
class PlainPanel
  @tag_name = "plain-panel"
  def initialize
  end
  def html
    %Q{<p class="plain">plain</p>}
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "LazyFormat.rb"), `
class LazyFormat
  @tag_name = "lazy-format"
  def initialize
  end
  def html
    %Q{<p class="lazy">{MochiFormat.decimal(1234.5, "en-US")}</p>}
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
    <plain-panel></plain-panel>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const lazyManifest = JSON.parse(
    fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"),
  );
  expect(lazyManifest.schema_version).toBe(2);
  expect(lazyManifest.format_host).toBe("mochi-format.js");
  expect(lazyManifest.capabilities.formatting.host).toBe("mochi-format.js");
  const plain = readComponentDescriptor(bundleDir, lazyManifest, "plain-panel");
  const lazy = readComponentDescriptor(bundleDir, lazyManifest, "lazy-format");
  expect(plain.formatting).toBeUndefined();
  expect(lazy.formatting).toBe(true);

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));

  const { server, baseURL } = await startStaticServer(bundleDir);
  try {
    await page.goto(`${baseURL}/index.html`);
    await expect(page.locator("plain-panel").locator("p.plain")).toHaveText("plain");
    expect(requested.filter((url) => url.endsWith("/mochi-format.js"))).toHaveLength(0);
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.json"))).toHaveLength(0);
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.chi"))).toHaveLength(0);
    expect(requested.filter((url) => /\/components\/ruby-[0-9a-f]+\.chi$/.test(url))).toHaveLength(0);

    await page.evaluate(() => {
      document.body.appendChild(document.createElement("lazy-format"));
    });
    await expect(page.locator("lazy-format").locator("p.lazy")).toHaveText("1,234.5");
    expect(requested.filter((url) => url.endsWith("/mochi-format.js"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.chi"))).toHaveLength(1);
    expect(requested.filter((url) => /\/components\/ruby-[0-9a-f]+\.chi$/.test(url))).toHaveLength(1);

    await page.evaluate(async () => {
      document.querySelector("lazy-format")?.remove();
      await new Promise((resolve) => setTimeout(resolve, 0));
      document.body.appendChild(document.createElement("lazy-format"));
    });
    await expect(page.locator("lazy-format").locator("p.lazy")).toHaveText("1,234.5");
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/lazy-format.chi"))).toHaveLength(1);
    expect(requested.filter((url) => /\/components\/ruby-[0-9a-f]+\.chi$/.test(url))).toHaveLength(1);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM entry visit fetches only the active component descriptor closure", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-lazy-descriptor-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "lib", "styles"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "styles", "costs.css"), `
    .costs { border: 1px solid rgb(10, 20, 30); }
  `);
  fs.writeFileSync(path.join(projectDir, "lib", "HomeScreen.rb"), `
class HomeScreen
  @tag_name = "home-screen"

  def initialize
  end

  def html
    %Q{<section class="home"><p class="label">home</p></section>}
  end

  def css
    %Q{:host { display: block; } .label { color: rgb(1, 2, 3); }}
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "lib", "CostsScreen.rb"), `
class CostsScreen
  @tag_name = "costs-screen"

  def initialize
    @total = 42
  end

  def html
    %Q{<section class="costs"><p class="total">{@total}</p></section>}
  end

  def css
    %Q{
      @import "styles/costs.css";
      :host { display: block; }
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
    <home-screen></home-screen>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const manifest = readManifest(bundleDir);
  expect(manifest.schema_version).toBe(2);
  expect(manifest.components.map((component: any) => component.tag_name).sort())
    .toEqual(["costs-screen", "home-screen"]);
  const homeDescriptor = readComponentDescriptor(bundleDir, manifest, "home-screen");
  const costsDescriptor = readComponentDescriptor(bundleDir, manifest, "costs-screen");
  const homeStyleIds = new Set(homeDescriptor.style_resources || []);
  const costsStyleIds: string[] = costsDescriptor.style_resources || [];
  const sharedStyleFiles: string[] = costsStyleIds.map((id: string) => manifest.resources[id].file);
  expect(sharedStyleFiles.length).toBeGreaterThan(0);
  costsStyleIds.forEach((id) => expect(homeStyleIds.has(id)).toBe(false));
  sharedStyleFiles.forEach((file) => {
    expect(fs.existsSync(path.join(bundleDir, file))).toBe(true);
  });

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));

  const { server, baseURL } = await startStaticServer(bundleDir);
  try {
    await page.goto(`${baseURL}/index.html`);
    await expect(page.locator("home-screen").locator("p.label")).toHaveText("home");

    expect(requested.filter((url) => url.endsWith("/components/home-screen.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/costs-screen.json"))).toHaveLength(0);
    expect(requested.filter((url) => url.endsWith("/components/costs-screen.chi"))).toHaveLength(0);
    sharedStyleFiles.forEach((file) => {
      expect(requested.filter((url) => url.endsWith(`/${file}`))).toHaveLength(0);
    });

    await page.evaluate(() => {
      document.body.appendChild(document.createElement("costs-screen"));
      document.body.appendChild(document.createElement("costs-screen"));
    });
    await expect(page.locator("costs-screen")).toHaveCount(2);
    await expect(page.locator("costs-screen").nth(0).locator("p.total")).toHaveText("42");
    await expect(page.locator("costs-screen").nth(1).locator("p.total")).toHaveText("42");

    expect(requested.filter((url) => url.endsWith("/components/costs-screen.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/costs-screen.chi"))).toHaveLength(1);
    sharedStyleFiles.forEach((file) => {
      expect(requested.filter((url) => url.endsWith(`/${file}`))).toHaveLength(1);
    });

    const reopen = await page.evaluate(async () => {
      const stats = () => (window as any).MochiLoader.debugStats();
      const existing = Array.from(document.querySelectorAll("costs-screen")) as any[];
      const before = stats();
      const firstInstance = String(existing[0]._mochiInstance);
      existing.forEach((element) => element.remove());
      await new Promise((resolve) => setTimeout(resolve, 0));
      const removed = stats();
      const reopened = document.createElement("costs-screen") as any;
      document.body.appendChild(reopened);
      await reopened._mochiReady;
      return {
        before,
        removed,
        after: stats(),
        firstInstance,
        reopenedInstance: String(reopened._mochiInstance),
      };
    });
    await expect(page.locator("costs-screen").locator("p.total")).toHaveText("42");
    expect(reopen.removed.components).toBe(reopen.before.components - 2);
    expect(reopen.after.components).toBe(reopen.before.components - 1);
    expect(reopen.after.elements).toBe(reopen.before.elements - 1);
    expect(reopen.reopenedInstance).not.toBe(reopen.firstInstance);

    expect(requested.filter((url) => url.endsWith("/components/costs-screen.json"))).toHaveLength(1);
    expect(requested.filter((url) => url.endsWith("/components/costs-screen.chi"))).toHaveLength(1);
    sharedStyleFiles.forEach((file) => {
      expect(requested.filter((url) => url.endsWith(`/${file}`))).toHaveLength(1);
    });
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM formatting works from a shared helper in the same Ruby file", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-format-helper-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "HelperFormat.rb"), `
class SharedFormat
  def self.label(value)
    MochiFormat.currency(value, "USD", "en-US", 2)
  end
end

class HelperFormatPanel
  @tag_name = "helper-format-panel"

  def initialize
  end

  def html
    %Q{<p class="label">{SharedFormat.label(123456)}</p>}
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
    <helper-format-panel></helper-format-panel>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const helperManifest = JSON.parse(
    fs.readFileSync(path.join(bundleDir, "mochi-manifest.json"), "utf8"),
  );
  expect(helperManifest.schema_version).toBe(2);
  expect(helperManifest.format_host).toBe("mochi-format.js");
  expect(helperManifest.capabilities.formatting.host).toBe("mochi-format.js");
  const helperDescriptor = readComponentDescriptor(bundleDir, helperManifest, "helper-format-panel");
  expect(helperDescriptor.formatting).toBe(true);
  expect(helperDescriptor.capabilities).toContain("formatting");
  expect(helperDescriptor.helper_chi).toMatch(/^mochi-helpers-/);

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));

  const { server, baseURL } = await startStaticServer(bundleDir);
  try {
    await page.goto(`${baseURL}/index.html`);
    await expect(page.locator("helper-format-panel").locator("p.label"))
      .toHaveText("$1,234.56");
    expect(requested.filter((url) => url.endsWith("/mochi-format.js"))).toHaveLength(1);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("GVM formatting host load failure reports an actionable mount error", async ({ page }) => {
  setupConsoleLogging(page);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-gvm-format-fail-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });

  fs.writeFileSync(path.join(projectDir, "lib", "FormatFail.rb"), `
class FormatFail
  @tag_name = "format-fail"
  def initialize
  end
  def html
    %Q{<p class="value">{MochiFormat.decimal(1, "en-US")}</p>}
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
    <format-fail></format-fail>
  </body>
</html>
`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  await page.route("**/mochi-format.js", (route) => {
    route.fulfill({ status: 404, contentType: "text/plain", body: "missing" });
  });
  await page.addInitScript(() => {
    (window as any).__mochiFormatFailures = [];
    document.addEventListener("mochi:error", (event: any) => {
      (window as any).__mochiFormatFailures.push(event.detail);
    });
  });

  const { server, baseURL } = await startStaticServer(bundleDir);
  try {
    await page.goto(`${baseURL}/index.html`);
    await expect.poll(async () => page.evaluate(
      () => (window as any).__mochiFormatFailures.length,
    )).toBe(1);
    const failure = await page.evaluate(
      () => (window as any).__mochiFormatFailures[0],
    );
    expect(failure.phase).toBe("capability");
    expect(failure.message).toMatch(/host capability 'formatting'/);
    expect(failure.message).toMatch(/mochi-format\.js/);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});
