import { expect, test } from "@playwright/test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";

const fixture = path.join(__dirname, "../fixtures/clay_inspector");

test("station inspector uses real DOM buttons and preserves keyed state through layout changes", async ({ page }) => {
  await withCompiledProject(fixture, async url => {
    await page.setViewportSize({ width: 640, height: 660 });
    await page.goto(url);
    const host = page.locator("record-inspector");
    const station = host.getByRole("button", { pressed: true });
    const selection = host.locator(".selection");
    await expect(host.locator(".record")).toHaveCount(3);
    await expect(station).toHaveText("Harbor weather station");
    await expect(selection).toHaveText("Selected station 01");

    const cafe = host.getByRole("button", { name: /^Café observation/ });
    await cafe.click();
    await expect(station).toHaveText(/^Café observation/);
    await expect(selection).toHaveText("Selected station 02");
    const harbor = host.getByRole("button", { name: "Harbor weather station" });
    await harbor.focus();
    const original = await harbor.elementHandle();
    // Activate the order control while the keyed row owns keyboard focus.
    await host.getByRole("button", { name: "Reverse order" }).evaluate((button: HTMLButtonElement) => button.click());
    await expect(host.locator(".record").first()).toHaveText("West ridge sensor");
    expect(await harbor.evaluate((button, previous) => button === previous, original)).toBe(true);
    await expect(harbor).toBeFocused();
    await expect(selection).toHaveText("Selected station 02");

    const details = host.getByRole("button", { name: "Details" });
    await details.press("Space");
    await expect(host.locator(".detail")).toHaveText("Showing details for station 02");
    const fontLoaded = await page.evaluate(async () => {
      const faces = await document.fonts.load('16px StationSans', 'Café');
      return faces.some(face => face.status === "loaded");
    });
    expect(fontLoaded).toBe(true);
    const wideHeight = await cafe.evaluate(button => button.getBoundingClientRect().height);
    await page.setViewportSize({ width: 320, height: 660 });
    await expect.poll(() => cafe.evaluate(button => button.getBoundingClientRect().height)).toBeGreaterThan(wideHeight);
    await expect(details).toBeFocused();
    await expect(host.locator("canvas")).toHaveCount(0);

    await host.evaluate(element => element.remove());
    await expect(host).toHaveCount(0);
    await page.evaluate(() => document.body.append(document.createElement("record-inspector")));
    await expect(selection).toHaveText("Selected station 01");
    await expect(host.locator(".detail")).toHaveCount(0);
  });
});

test("station inspector Ruby scenario passes through mochi test", ({ browserName }) => {
  expect(runRubyProject(fixture, browserName, "inspector_test.rb"))
    .toContain(`PASS [${browserName}] select a station, reorder the rows, and inspect its details`);
});

test("station inspector Ruby scenario reports a wrong assertion at the authored step", ({ browserName }) => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-inspector-"));
  try {
    fs.cpSync(fixture, project, { recursive: true });
    const scenario = path.join(project, "test/inspector_test.rb");
    const source = fs.readFileSync(scenario, "utf8");
    fs.writeFileSync(scenario, source.replace('"Selected station 02"', '"Selected station 99"'));

    expect(() => runRubyProject(project, browserName, "inspector_test.rb")).toThrow(
      "inspector_test.rb:5: expected 'Selected station 99' at '[data-view='selection']', got 'Selected station 02' (step 4 assert_text [data-view='selection'])",
    );
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
