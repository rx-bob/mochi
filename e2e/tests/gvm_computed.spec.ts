import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { withCompiledProject } from "./framework_helpers";
import { computedFixtureVM } from "./computed_fixture_vm";

const fixture = path.join(__dirname, "../fixtures/ui_contracts/probes/12-computed");

test("explicit computed values share evaluations and recover @ui-inspector", async ({ page }) => {
  test.setTimeout(180_000);
  const vm = computedFixtureVM();
  try {
    await withCompiledProject(fixture, async (baseURL, bundle) => {
      for (const name of ["mochi-gvm.js", "mochi-gvm.wasm"]) fs.copyFileSync(path.join(vm.directory, name), path.join(bundle, name));
      await page.addInitScript(() => {
        (window as any).__computedErrors = [];
        document.addEventListener("mochi:error", event => (window as any).__computedErrors.push((event as CustomEvent).detail));
      });
      // Capture the fixture-only export without relying on loader internals.
      await page.route("**/mochi-gvm.js", async route => {
        const response = await route.fetch();
        const source = await response.text();
        await route.fulfill({ response, body: source + `\nconst fixtureFactory = MochiModule; MochiModule = async function(options) { const mod = await fixtureFactory(options); window.__computedCalls = () => mod._goose_fixture_computed_calls(); return mod; };` });
      });
      await page.goto(baseURL);
      const roots = page.locator("probe-root");
      await expect(roots.nth(0).locator(".first")).toHaveText("6");
      await expect(roots.nth(1).locator(".first")).toHaveText("6");
      const calls = () => page.evaluate(() => (window as any).__computedCalls());
      expect(await calls()).toBe(4); // rows + label, independently for each instance
      await roots.nth(0).locator(".unrelated").click();
      await expect(roots.nth(0).locator(".seen")).toHaveText("6");
      expect(await calls()).toBe(4);
      await roots.nth(0).locator(".replace").click();
      for (const selector of [".first", ".second", ".third", ".seen"]) await expect(roots.nth(0).locator(selector)).toHaveText("9");
      expect(await calls()).toBe(6);
      await expect(roots.nth(1).locator(".first")).toHaveText("6");
      await roots.nth(0).locator(".twice").click();
      await expect(roots.nth(0).locator(".first")).toHaveText("3");
      expect(await calls()).toBe(10);
      await roots.nth(0).locator(".fail").click();
      await expect.poll(() => page.evaluate(() => (window as any).__computedErrors.length)).toBe(1);
      await expect(roots.nth(0).locator(".first")).toHaveText("3");
      const failure = await page.evaluate(() => (window as any).__computedErrors[0]);
      expect(failure.message).toContain("division by zero");
      expect(failure.method).toBe("rows");
      const lines = fs.readFileSync(path.join(fixture, "lib/ProbeRoot.rb"), "utf8").split("\n");
      expect(failure.source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def rows") + 1}`);
      expect(await calls()).toBe(12);
      await roots.nth(0).locator(".recover").click();
      await expect(roots.nth(0).locator(".first")).toHaveText("6");
      await expect(roots.nth(0).locator(".second")).toHaveText("6");
      expect(await calls()).toBe(14);
      await roots.nth(0).locator(".effect").click();
      await expect.poll(() => page.evaluate(() => (window as any).__computedErrors.length)).toBe(2);
      const effect = await page.evaluate(() => (window as any).__computedErrors[1]);
      expect(effect.message).toContain("computed evaluation must not mutate state or emit host effects");
      expect(effect.method).toBe("effect");
      expect(effect.source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def effect") + 1}`);
      await expect(roots.nth(0).locator(".first")).toHaveText("6");
      expect(await calls()).toBe(15);
      await roots.nth(0).locator(".twice").click();
      await expect(roots.nth(0).locator(".first")).toHaveText("3");
      expect(await calls()).toBe(17); // the rejected effect did not change records
      await page.evaluate(() => document.querySelector("probe-root")!.remove());
      await page.evaluate(() => document.body.appendChild(document.createElement("probe-root")));
      await expect(roots.nth(1).locator(".first")).toHaveText("6");
      expect(await calls()).toBe(19);
      expect(await page.evaluate(() => (window as any).__computedErrors.length)).toBe(2);
    }, "<probe-root></probe-root><probe-root></probe-root>");
  } finally {
    vm.cleanup();
  }
});

test("computed declarations typecheck with original method lines @ui-inspector", async () => {
  await withCompiledProject(fixture, async (_baseURL, bundle) => {
    expect(fs.existsSync(path.join(bundle, "mochi-manifest.json"))).toBe(true);
  }, "<probe-root></probe-root>", ["--typecheck"]);
});
