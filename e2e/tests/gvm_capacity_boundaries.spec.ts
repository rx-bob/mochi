import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect, Page } from "@playwright/test";

test.describe.configure({ mode: "serial" });
const repo = path.resolve(__dirname, "../..");
const capacities = {
  scratch_objects: 128, scratch_bytes: 8192, scratch_slots: 256,
  scratch_ivars: 32, state_components: 2, bindings: 4, host_patch_bytes: 1024,
  state_bytes: 524288,
  host_emit_envelope_bytes: 1024,
  // Keep the optional file decoder's reservation valid under the deliberately
  // tiny scratch byte pool; this suite does not exercise file capabilities.
  host_file_chunk_bytes: 2048,
};
const probe = `class CapacityProbe
  @tag_name = "capacity-probe"
  @value
  def initialize
    @value = "ready"
  end
  def valid
    @value = "valid"
  end
  def objects
    rows = []
    i = 0
    while i < 150
      rows.push("x")
      i = i + 1
    end
  end
  def slots
    rows = []
    i = 0
    while i < 257
      rows.push(i)
      i = i + 1
    end
  end
  def bytes
    text = "${"x".repeat(9000)}"
    @value = text
  end
  def patch
    @value = "${"p".repeat(1500)}"
  end
  def commands
    i = 0
    while i < 300
      Mochi.storage_set("capacity-command", "must-not-publish")
      i = i + 1
    end
  end
  def fail_after_command
    Mochi.storage_set("capacity-failed", "must-not-publish")
    objects
  end
  def emits
    i = 0
    while i < 100
      Mochi.emit("capacity-no-listeners", {"value" => "bad"})
      i = i + 1
    end
  end
  def fetches
    i = 0
    while i < 1000
      Mochi.fetch("/must-not-run", "valid")
      i = i + 1
    end
  end
  def html
    %Q{<p>{@value}</p><button onclick="{valid}">valid</button><button onclick="{objects}">objects</button><button onclick="{slots}">slots</button><button onclick="{bytes}">bytes</button><button onclick="{patch}">patch</button><button onclick="{commands}">commands</button><button onclick="{fail_after_command}">fail_after_command</button><button onclick="{emits}">emits</button><button onclick="{fetches}">fetches</button>}
  end
end
`;
const bindingProbe = `class BindingProbe
  @tag_name = "binding-probe"
  @value
  def initialize
    @value = "ready"
  end
  def html
    %Q{<p>{@value}</p><p>{@value}</p><p>{@value}</p><p>{@value}</p><p>{@value}</p>}
  end
end
`;
const propsProbe = `class PropsProbe
  @tag_name = "props-probe"
  prop :rows, Array, default: []
  def html
    %Q{<p>{@rows.length}</p>}
  end
end
`;

let directory: string, server: http.Server, url: string;
test.beforeAll(async () => {
  test.setTimeout(240_000);
  directory = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-capacity-boundaries-"));
  fs.mkdirSync(path.join(directory, "lib"));
  for (const [name, source] of Object.entries({ CapacityProbe: probe, BindingProbe: bindingProbe, PropsProbe: propsProbe })) {
    fs.writeFileSync(path.join(directory, "lib", `${name}.rb`), source);
  }
  fs.copyFileSync(path.join(repo, "e2e/fixtures/ui_contracts/probes/13-capacity-lifecycle/lib/CapacityComputedRoot.rb"), path.join(directory, "lib/CapacityComputedRoot.rb"));
  fs.writeFileSync(path.join(directory, "index.html"), '<!doctype html><script src="mochi-loader.js"></script>');
  fs.writeFileSync(path.join(directory, "capacity.json"), JSON.stringify({ schema_version: 1, capacities }));
  const bundle = path.join(directory, "bundle");
  execFileSync(path.join(repo, "compiler/mochi"), ["-i", directory, "-o", bundle,
    "--capacity-config", path.join(directory, "capacity.json")], { cwd: repo, stdio: "pipe" });
  server = http.createServer((request, response) => {
    const file = path.resolve(bundle, "." + (request.url === "/" ? "/index.html" : request.url!.split("?")[0]));
    if (!file.startsWith(bundle + path.sep)) { response.writeHead(403).end(); return; }
    fs.readFile(file, (error, bytes) => {
      if (error) { response.writeHead(404).end(); return; }
      const types: Record<string, string> = { ".wasm": "application/wasm", ".js": "text/javascript", ".json": "application/json", ".html": "text/html" };
      response.writeHead(200, { "content-type": types[path.extname(file)] || "application/octet-stream" }).end(bytes);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${(server.address() as any).port}`;
});

for (const [action, resource, limit, method] of [
  ["objects", "scratch objects", 128, "projection"],
  ["bytes", "scratch bytes", 8192, "projection"],
  ["cache", "computed cache entries", 4, "four"],
  ["state", "state bytes", 524288, "fill_state"],
] as const) {
  test(`computed lifecycle: ${resource} preserves DOM and recovers with an independent instance`, async ({ page }) => {
    const crashes: string[] = [];
    page.on("pageerror", error => crashes.push(error.message));
    await page.goto(url);
    expect(await mount(page)).toBe("");
    expect(await mount(page, "capacity-computed-root")).toBe("");
    const host = page.locator("capacity-computed-root");
    await expect(host.locator(".projection")).toHaveText("1");
    await host.locator(`.${action}`).click();
    await expect.poll(() => host.evaluate((el: any) => el.mochiError?.message || "")).toContain(`${resource} exhausted`);
    const error = await host.evaluate((el: any) => el.mochiError);
    expect(error.message).toMatch(new RegExp(`requested \\d+, used \\d+ of ${limit}`));
    expect(error.message).toMatch(/capacity profile [a-f0-9]{64}/);
    const source = fs.readFileSync(path.join(directory, "lib/CapacityComputedRoot.rb"), "utf8").split("\n");
    expect(error.message).toContain(`lib/CapacityComputedRoot.rb:${source.indexOf(`  def ${method}`) + 1}`);
    await expect(host.locator(".status")).toHaveText("ready");
    await expect(host.locator(".projection")).toHaveText("1");
    expect(await page.evaluate(() => localStorage.getItem("capacity-projection"))).toBeNull();
    // Recovery is possible without rolling back arbitrary preceding writes.
    await page.locator("capacity-probe").getByRole("button", { name: "valid", exact: true }).click();
    await expect(page.locator("capacity-probe p")).toHaveText("valid");
    await host.locator(".recover").click();
    await expect(host.locator(".status")).toHaveText(action === "state" ? /^pending:[1-9]\d*:recovered$/ : "pending:0:recovered");
    await expect(host.locator(".projection")).toHaveText("1");
    await host.evaluate(el => el.remove());
    expect(await mount(page, "capacity-computed-root")).toBe("");
    await expect(page.locator("capacity-computed-root .projection")).toHaveText("1");
    expect(await page.evaluate(() => localStorage.getItem("capacity-projection"))).toBeNull();
    expect(crashes).toEqual([]);
  });
}

test("failed computed mount releases caches and bindings before a valid remount", async ({ page }) => {
  await page.goto(url);
  expect(await mount(page)).toBe("");
  // More failed mounts than cache slots: even one leaked entry per failure
  // would change the resource or prevent the final healthy mount.
  for (let attempt = 0; attempt < 6; attempt++) {
    const failure = await page.evaluate(async () => {
      await customElements.whenDefined("capacity-computed-root");
      const el = document.createElement("capacity-computed-root") as any;
      el.setAttribute("fail_mount", "true");
      document.body.appendChild(el);
      try { await el._mochiReady; return "unexpected success"; }
      catch (error) { return String(error); }
    });
    expect(failure).toContain("scratch objects exhausted");
    expect(failure).toContain("lib/CapacityComputedRoot.rb:");
    expect(await page.locator("capacity-computed-root").evaluate(el => el.shadowRoot?.querySelector(".status")?.textContent)).not.toBe("ready");
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().components)).toBe(1);
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().bindings)).toBe(1);
    await page.locator("capacity-computed-root").evaluate(el => el.remove());
    await page.locator("capacity-probe").getByRole("button", { name: "valid", exact: true }).click();
    await expect(page.locator("capacity-probe p")).toHaveText("valid");
  }
  expect(await mount(page, "capacity-computed-root")).toBe("");
  await expect(page.locator("capacity-computed-root .projection")).toHaveText("1");
  await page.locator("capacity-probe").getByRole("button", { name: "valid", exact: true }).click();
  await expect(page.locator("capacity-probe p")).toHaveText("valid");
});
test.afterAll(async () => {
  if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  if (directory) fs.rmSync(directory, { recursive: true, force: true });
});

async function mount(page: Page, tag = "capacity-probe", rows?: string[]) {
  return page.evaluate(async ({ tag, rows }) => {
    await customElements.whenDefined(tag);
    const element = document.createElement(tag) as any;
    if (rows) element.setAttribute("rows", JSON.stringify(rows));
    document.body.appendChild(element);
    try { await element._mochiReady; return ""; }
    catch (error) { return String(error); }
  }, { tag, rows });
}

for (const [action, resource, limit] of [
  ["objects", "scratch objects", 128], ["slots", "scratch slots", 256],
  ["bytes", "scratch bytes", 8192], ["patch", "ABI patch bytes", 1024],
  ["commands", "host command bytes", 1023], ["fail_after_command", "scratch objects", 128],
  ["emits", "ABI emit bytes", 1023], ["fetches", "ABI fetch bytes", 65535],
] as const) {
  test(`${resource}: ${action} rejects whole batch and recovers`, async ({ page }) => {
    const crashes: string[] = [];
    const leakedRequests: string[] = [];
    page.on("pageerror", (error) => crashes.push(error.message));
    page.on("request", (request) => { if (request.url().includes("/must-not-run")) leakedRequests.push(request.url()); });
    await page.goto(url);
    expect(await mount(page)).toBe("");
    expect(await mount(page)).toBe("");
    const host = page.locator("capacity-probe").first();
    await expect(host.locator("p")).toHaveText("ready");
    await host.getByRole("button", { name: action, exact: true }).click();
    await expect.poll(() => host.evaluate((el: any) => el.mochiError?.message || "")).toContain(`${resource} exhausted`);
    const error = await host.evaluate((el: any) => el.mochiError.message);
    expect(error).toContain(`of ${limit}`);
    expect(error).toContain("requested ");
    expect(error).toContain("lib/CapacityProbe.rb:");
    expect(error).toMatch(/capacity profile [a-f0-9]{64}/);
    await expect(host.locator("p")).toHaveText("ready");
    const other = page.locator("capacity-probe").last();
    await other.getByRole("button", { name: "valid", exact: true }).click();
    await expect(other.locator("p")).toHaveText("valid");
    await host.getByRole("button", { name: "valid", exact: true }).click();
    await expect(host.locator("p")).toHaveText("valid");
    expect(await page.evaluate(() => [localStorage.getItem("capacity-command"), localStorage.getItem("capacity-failed")])).toEqual([null, null]);
    expect(crashes).toEqual([]);
    expect(leakedRequests).toEqual([]);
  });
}

test("component registrations reject at the profile bound and disposal frees one slot", async ({ page }) => {
  await page.goto(url);
  expect(await mount(page)).toBe("");
  expect(await mount(page)).toBe("");
  const failure = await mount(page);
  expect(failure).toContain("component registrations exhausted (requested 1, used 2 of 2)");
  expect(failure).toContain("lib/CapacityProbe.rb:");
  await page.locator("capacity-probe").nth(1).evaluate((el) => el.remove());
  await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().components)).toBe(1);
  expect(await mount(page)).toBe("");
  await page.locator("capacity-probe").first().getByRole("button", { name: "valid", exact: true }).click();
  await expect(page.locator("capacity-probe").first().locator("p")).toHaveText("valid");
});

test("partial binding registrations are removed after a failed mount", async ({ page }) => {
  await page.goto(url);
  expect(await mount(page)).toBe("");
  const failure = await mount(page, "binding-probe");
  expect(failure).toContain("bindings exhausted (requested 1, used 4 of 4)");
  expect(failure).toContain("lib/BindingProbe.rb:");
  expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().bindings)).toBe(1);
  await page.locator("binding-probe").evaluate((el) => el.remove());
  expect(await mount(page)).toBe("");
});

test("oversized deep-copy props report allocation failure and permit a valid remount", async ({ page }) => {
  await page.goto(url);
  expect(await mount(page)).toBe("");
  const failure = await mount(page, "props-probe", Array(150).fill("x"));
  expect(failure).toContain("scratch objects exhausted");
  expect(failure).toContain("lib/PropsProbe.rb:");
  await page.locator("props-probe").evaluate((el) => el.remove());
  expect(await mount(page, "props-probe", ["retained"])).toBe("");
  await expect(page.locator("props-probe p")).toHaveText("1");
  await page.locator("capacity-probe").getByRole("button", { name: "valid", exact: true }).click();
  await expect(page.locator("capacity-probe p")).toHaveText("valid");
});

