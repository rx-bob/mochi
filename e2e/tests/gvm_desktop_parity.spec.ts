import { expect, test, type Page } from "@playwright/test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";
import { captureDOM, compareObservations, comparePaint, type Capture } from "./inspector_capture";

const { runCase } = require("../mochi_test_runner.cjs");

const fixture = path.join(__dirname, "../fixtures/clay_inspector");
const matrix = JSON.parse(fs.readFileSync(path.join(fixture, "parity.json"), "utf8"));
const artifactRoot = process.env.MOCHI_PARITY_DIR;

for (const width of matrix.widths as number[]) {
  test(`inspector capture parity at ${width} points`, async ({ browser, browserName }, testInfo) => {
    test.skip(!artifactRoot || !matrix.paint[browserName], "requires native inspector captures and a renderer in the matrix");
    const output = path.join(artifactRoot!, browserName);
    fs.mkdirSync(output, { recursive: true });
    const plan = JSON.parse(fs.readFileSync(path.join(artifactRoot!, "test-plan.json"), "utf8"));
    expect(plan.tests).toHaveLength(1);

    await withCompiledProject(fixture, async (baseURL, bundle) => {
      // Preserve the entry page and local font. The recorder mounts the host.
      // Remove the demo page's outer margin and width cap for the content crop.
      const entry = path.join(bundle, "index.html");
      const html = fs.readFileSync(entry, "utf8")
        .replace("<record-inspector></record-inspector>", "")
        .replace("</style>", "body { margin: 0; } record-inspector { max-width: none; }\n</style>");
      fs.writeFileSync(entry, html);
      const sizedBrowser = {
        newPage: () => browser.newPage({
          viewport: { width, height: 660 }, deviceScaleFactor: matrix.scale, colorScheme: "light",
        }),
      };
      const captures: { name: string; dom: Capture; native: Capture; mismatches: unknown[] }[] = [];
      await runCase(sizedBrowser, browserName, baseURL, plan.tests[0], async (page: Page, name: string) => {
        expect(matrix.checkpoints).toContain(name);
        const testName = `${width}-${name}`;
        const domStem = path.join(output, testName);
        const nativeStem = path.join(artifactRoot!, "native", testName);
        const dom = await captureDOM(page, domStem);
        const native: Capture = JSON.parse(fs.readFileSync(nativeStem + ".json", "utf8"));
        const mismatches: unknown[] = compareObservations(dom, native, matrix.edgeTolerance);
        const paint = await comparePaint(page, dom, native, domStem + ".png", nativeStem + ".png", domStem + ".diff.png", matrix);
        for (const solid of paint.solids) mismatches.push({ ...solid, check: "solid fill pixels" });
        const limits = matrix.paint[browserName];
        for (const [id, actual] of Object.entries(paint.fractions)) {
          const ceiling = (dom.focus === id ? limits.focused[id] : undefined) ?? limits.regions[id];
          if (ceiling === undefined || !Number.isFinite(actual) || actual > ceiling)
            mismatches.push({ control: id, check: "paint fraction", actual, ceiling });
        }
        if (paint.sizes.some(([w, h], index) => w !== width * matrix.scale ||
            h !== Math.ceil((index === 0 ? dom : native).height * matrix.scale))) {
          mismatches.push({ control: "panel", check: "capture resolution", sizes: paint.sizes });
        }
        const report = domStem + ".comparison.json";
        fs.writeFileSync(report, JSON.stringify({
          browser: browserName, browserVersion: browser.version(), width, name, paint, mismatches,
        }, null, 2));
        await testInfo.attach(testName, { path: report, contentType: "application/json" });
        if (mismatches.length) {
          for (const [label, image] of [["dom", domStem], ["appkit", nativeStem], ["diff", domStem + ".diff"]]) {
            await testInfo.attach(`${testName}-${label}`, { path: image + ".png", contentType: "image/png" });
          }
        }
        captures.push({ name, dom, native, mismatches });
      });
      expect(captures.map(capture => capture.name)).toEqual(matrix.checkpoints);
      for (const capture of captures) {
        expect(capture.mismatches, `${browserName} ${width} ${capture.name}, first mismatch ${JSON.stringify(capture.mismatches[0])}`).toEqual([]);
      }

      const selected = captures[0];
      const padding = structuredClone(selected.native);
      padding.controls.find(c => c.id === "action-reverse")!.rect[0] += 2;
      expect(compareObservations(selected.dom, padding, matrix.edgeTolerance)[0]).toMatchObject({ control: "action-reverse", check: "left" });
      const wrap = structuredClone(selected.native);
      wrap.controls.find(c => c.id === "station-02")!.lines = ["Café observation"];
      expect(compareObservations(selected.dom, wrap, matrix.edgeTolerance)[0]).toMatchObject({ control: "station-02", check: "lines" });
      const focus = { ...selected.native, focus: null };
      expect(compareObservations(selected.dom, focus, matrix.edgeTolerance)[0]).toMatchObject({ control: "station-02", check: "focus" });
    });
  });
}

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
