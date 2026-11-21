import { expect, test, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";
import { captureDOM, compareObservations, comparePaint, type Capture } from "./inspector_capture";

const { runCase } = require("../mochi_test_runner.cjs");

const fixture = path.join(__dirname, "../fixtures/clay_inspector");
const matrix = JSON.parse(fs.readFileSync(path.join(fixture, "parity.json"), "utf8"));
const artifactRoot = process.env.MOCHI_PARITY_DIR;

const sizes = (matrix.widths as number[]).map(width => ({ width, scale: matrix.scale as number }));
sizes.push(...(matrix.wrapWidths as number[]).map(width => ({ width, scale: 1 })));
for (const { width, scale } of sizes) {
  test(`inspector capture parity at ${width} points (${scale}x)`, async ({ browser, browserName }, testInfo) => {
    test.skip(!artifactRoot || !matrix.paint[browserName], "requires native inspector captures and a renderer in the matrix");
    const output = path.join(artifactRoot!, scale === 2 ? browserName : browserName + "-1x");
    fs.mkdirSync(output, { recursive: true });
    const plan = JSON.parse(fs.readFileSync(path.join(artifactRoot!, "test-plan.json"), "utf8"));
    expect(plan.tests).toHaveLength(1);

    await withCompiledProject(fixture, async (baseURL, bundle) => {
      // The recorder mounts the host in the built entry shell.
      const entry = path.join(bundle, "index.html");
      const html = fs.readFileSync(entry, "utf8")
        .replace("<record-inspector></record-inspector>", "");
      fs.writeFileSync(entry, html);
      const sizedBrowser = {
        newPage: () => browser.newPage({
          viewport: { width, height: 780 }, deviceScaleFactor: scale, colorScheme: "light",
        }),
      };
      const captures: { name: string; dom: Capture; native: Capture; mismatches: unknown[] }[] = [];
      await runCase(sizedBrowser, browserName, baseURL, plan.tests[0], async (page: Page, name: string) => {
        expect(matrix.checkpoints).toContain(name);
        const testName = `${width}-${name}`;
        const domStem = path.join(output, testName);
        const nativeStem = path.join(artifactRoot!, scale === 2 ? "native" : "native-1x", testName);
        const dom = await captureDOM(page, domStem);
        const native: Capture = JSON.parse(fs.readFileSync(nativeStem + ".json", "utf8"));
        const mismatches: unknown[] = compareObservations(dom, native, matrix.edgeTolerance);
        const paint = await comparePaint(page, dom, native, domStem + ".png", nativeStem + ".png", domStem + ".diff.png", matrix);
        for (const solid of paint.solids) mismatches.push({ ...solid, check: "solid fill pixels" });
        const limits = matrix.paint[browserName];
        const override = scale === 1 ? matrix.paint1x[browserName] : undefined;
        const regions = { ...limits.regions, ...override?.regions };
        const focused = { ...limits.focused, ...override?.focused };
        for (const [id, actual] of Object.entries(paint.fractions)) {
          const ceiling = (dom.focus === id ? focused[id] : undefined) ?? regions[id];
          if (ceiling === undefined || !Number.isFinite(actual) || actual > ceiling)
            mismatches.push({ control: id, check: "paint fraction", actual, ceiling });
        }
        if (paint.sizes.some(([w, h], index) => w !== width * scale ||
            h !== Math.ceil((index === 0 ? dom : native).height * scale))) {
          mismatches.push({ control: "panel", check: "capture resolution", sizes: paint.sizes });
        }
        const report = domStem + ".comparison.json";
        fs.writeFileSync(report, JSON.stringify({
          browser: browserName, browserVersion: browser.version(), width, scale, name, paint, mismatches,
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

      const contentWidth = Math.min(width - 48, 520);
      for (const { dom, native } of captures) {
        expect(native.controls.find(control => control.id === "title")!.lineFaces?.[0]).toContain("1");
        for (const host of [dom, native]) {
          const control = (id: string) => host.controls.find(entry => entry.id === id)!;
          expect(control("panel").rect.slice(0, 3)).toEqual([24, 24, contentWidth]);
          expect(control("actions").rect[0]).toBe(40);
          expect(control("action-reverse").rect.slice(2)).toEqual([108, 38]);
          if (contentWidth <= 315) {
            expect(control("action-details").rect[0]).toBe(control("action-reverse").rect[0]);
            expect(control("action-details").rect[1] - control("action-reverse").rect[1]).toBe(46);
          } else {
            expect(control("action-details").rect[0] - control("action-reverse").rect[0]).toBe(116);
          }
          expect(control("station-02").rect[2]).toBe(contentWidth - 32);
          for (const id of ["action-reverse", "action-details"]) {
            const action = control(id);
            expect(action.lineFrames[0][0] - action.rect[0]).toBeCloseTo(8, 1);
          }
          expect(control("station-02").ink).toEqual([22, 45, 39]);
          const cafe = control("station-02");
          if (contentWidth === 315) expect(cafe.lines[0]).toBe("Café observation from the");
          if (contentWidth === 318) expect(cafe.lines[0]).toBe("Café observation from the northern");
        }
      }
      const initial = captures.find(capture => capture.name === "initial")!;
      const selected = captures.find(capture => capture.name === "selected")!;
      for (const host of ["dom", "native"] as const) {
        const existing = initial[host].controls;
        const updated = selected[host].controls;
        expect(updated.map(control => control.rect)).toEqual(existing.map(control => control.rect));
        expect(updated.filter((control, index) => JSON.stringify(control.fill) !== JSON.stringify(existing[index].fill))
          .map(control => [control.id, control.fill])).toEqual([
          ["station-01", [255, 255, 255]], ["station-02", [201, 231, 217]],
        ]);
      }
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

function visibleStations(capture: Capture) {
  const [, y, , height] = capture.scroll!.rect;
  return capture.controls.filter(control => control.id.startsWith("station-")).flatMap(control => {
    const [left, top, width, rowHeight] = control.rect;
    const visibleTop = Math.max(y, top);
    const visibleBottom = Math.min(y + height, top + rowHeight);
    return visibleBottom > visibleTop ? [{
      id: control.id, rect: [left, visibleTop, width, visibleBottom - visibleTop],
      clipped: visibleBottom - visibleTop < rowHeight,
    }] : [];
  });
}

for (const width of matrix.scrollWidths as number[]) {
  test(`inspector capture parity for station scrolling at ${width} points`, async ({ browser, browserName }) => {
    test.skip(!artifactRoot, "requires native scroll captures");
    const output = path.join(artifactRoot!, browserName + "-scroll");
    fs.mkdirSync(output, { recursive: true });
    const plan = JSON.parse(fs.readFileSync(path.join(artifactRoot!, "scroll-plan.json"), "utf8"));

    await withCompiledProject(fixture, async (url, bundle) => {
      const entry = path.join(bundle, "index.html");
      fs.writeFileSync(entry, fs.readFileSync(entry, "utf8").replace("<record-inspector></record-inspector>", ""));
      const sizedBrowser = { newPage: () => browser.newPage({ viewport: { width, height: 780 }, deviceScaleFactor: 2 }) };
      const offsets = new Map<string, number>();
      await runCase(sizedBrowser, browserName, url, plan.tests[0], async (page: Page, name: string) => {
        const stem = `${width}-${name}`;
        const domStem = path.join(output, stem);
        const nativeStem = path.join(artifactRoot!, "native-scroll", stem);
        const dom = await captureDOM(page, domStem);
        const native: Capture = JSON.parse(fs.readFileSync(nativeStem + ".json", "utf8"));
        expect(dom.scroll).toEqual(native.scroll);
        const visible = visibleStations(dom);
        expect(visible).toEqual(visibleStations(native));
        const paint = await comparePaint(page, dom, native, domStem + ".png", nativeStem + ".png", domStem + ".diff.png", matrix);
        expect(paint.solids).toEqual([]);
        const scroll = dom.scroll!;
        offsets.set(name, scroll.offset);
        if (name.endsWith("-bottom")) {
          expect(dom.focus).toBe("station-24");
          expect(native.focus).toBe(dom.focus);
          expect(scroll.offset).toBe(scroll.contentHeight - scroll.rect[3]);
          expect(visible.at(-1)).toMatchObject({ id: "station-24", clipped: false });
          expect(visible[0].clipped).toBe(true);
        }
      });
      expect(Array.from(offsets.keys())).toEqual(["expanded", "focused-bottom", "selected-bottom", "shortened"]);
      expect(offsets.get("focused-bottom")).toBeGreaterThan(0);
      expect(offsets.get("selected-bottom")).toBe(offsets.get("focused-bottom"));
      expect(offsets.get("shortened")).toBe(0);
    });
  });
}

test("wheel scrolling, resize and a Ruby update preserve station focus and a valid offset", async ({ page }) => {
  await withCompiledProject(fixture, async url => {
    await page.setViewportSize({ width: 364, height: 660 });
    await page.goto(url);
    const host = page.locator("record-inspector");
    const scroll = host.locator("[data-scroll=stations]");
    const toggle = host.locator("[data-list=toggle]");
    const details = host.getByRole("button", { name: "Details", exact: true });
    const offset = () => scroll.evaluate(element => element.scrollTop);
    const direction = () => host.locator(".actions").evaluate(element => getComputedStyle(element).flexDirection);

    await expect.poll(direction).toBe("row");
    await toggle.click();
    await expect(host.locator(".record")).toHaveCount(18);
    await scroll.hover();
    await page.mouse.wheel(0, 100);
    await expect.poll(offset).toBeGreaterThan(0);
    const last = host.locator("[data-id='24']");
    await host.locator("[data-id='23']").focus();
    await page.keyboard.press("Tab");
    await expect(last).toBeFocused();
    const before = await last.elementHandle();
    const bottom = await offset();
    await details.evaluate((button: HTMLButtonElement) => button.click());
    await expect(host.locator("[data-view=details]")).toHaveText("Showing details for station 01");
    expect(await offset()).toBe(bottom);
    await page.keyboard.press("Space");
    await expect(last).toHaveAttribute("aria-pressed", "true");
    expect(await offset()).toBe(bottom);

    await page.setViewportSize({ width: 363, height: 620 });
    await expect.poll(direction).toBe("column");
    await expect(last).toBeFocused();
    expect(await last.evaluate((node, original) => node === original, before)).toBe(true);
    expect(await scroll.evaluate(el => el.scrollTop <= el.scrollHeight - el.clientHeight)).toBe(true);
    await toggle.click();
    await expect(host.locator(".record")).toHaveCount(3);
    await expect.poll(offset).toBe(0);
  });
});

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
    await expect(host.locator("[data-view=details]")).toHaveText("Showing details for station 02");
    const fontLoaded = await cafe.evaluate(async element => {
      const style = getComputedStyle(element);
      const faces = await document.fonts.load(`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`, "Café");
      return faces.some(face => face.status === "loaded");
    });
    expect(fontLoaded).toBe(true);
    const wideHeight = await cafe.evaluate(button => button.getBoundingClientRect().height);
    await page.setViewportSize({ width: 320, height: 660 });
    await expect.poll(() => cafe.evaluate(button => button.getBoundingClientRect().height)).toBeGreaterThan(wideHeight);
    await expect(details).toBeFocused();
    await expect(host.locator("canvas")).toHaveCount(0);

    await page.setViewportSize({ width: 640, height: 660 });
    await harbor.press("Space");
    await expect(selection).toHaveText("Selected station 01");
    await harbor.press("Space");
    await expect(harbor).toHaveAttribute("aria-expanded", "true");
    await host.getByRole("button", { name: "Hide Harbor" }).press("Space");
    await expect(harbor).toHaveCount(0);
    await expect(cafe).toBeFocused();
    await cafe.press("Space");
    await expect(selection).toHaveText("Selected station 02");
    await original.evaluate(button => (button as HTMLButtonElement).click());
    await expect(selection).toHaveText("Selected station 02");

    await host.evaluate(element => element.remove());
    await expect(host).toHaveCount(0);
    await page.evaluate(() => document.body.append(document.createElement("record-inspector")));
    await expect(selection).toHaveText("Selected station 01");
    await expect(host.locator("[data-view=details]")).toHaveCount(0);
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
      "inspector_test.rb:8: expected 'Selected station 99' at '[data-view='selection']', got 'Selected station 02' (step 7 assert_text [data-view='selection'])",
    );
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});

test("station rows preserve local state and move focus after removal", ({ browserName }) => {
  expect(runRubyProject(fixture, browserName, "keyed_rows_test.rb"))
    .toContain(`PASS [${browserName}] retains expanded station state and returns focus after removal`);
});

test("keyed child lifetime and duplicate rejection replay from Ruby", ({ browserName }) => {
  expect(runRubyProject(path.join(fixture, "probes/keyed"), browserName, "keyed_lifetime_test.rb"))
    .toContain(`PASS [${browserName}] validates row keys and disposes only the removed Ruby instances`);
});

test("station details replays typed props and events using the Ruby runner", ({ browserName }) => {
  expect(runRubyProject(fixture, browserName, "details_test.rb"))
    .toContain(`PASS [${browserName}] updates one typed details panel and routes its confirmation`);
});

test("station details rejects invalid inputs while leaving siblings interactive", ({ browserName }) => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-rejected-details-"));
  try {
    fs.cpSync(fixture, project, { recursive: true });
    execFileSync("ruby", [path.join(fixture, "probes/reject_details.rb"), project]);
    expect(runRubyProject(project, browserName, "rejected_details_test.rb"))
      .toContain(`PASS [${browserName}] rejects invalid details inputs and keeps the inspector interactive`);
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});

test("a later portable screen requests its own font only on mount", async ({ page }) => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-screen-font-"));
  try {
    fs.cpSync(fixture, project, { recursive: true });
    const source = path.join(project, "lib/RecordInspector.rb");
    fs.writeFileSync(source, fs.readFileSync(source, "utf8").replace("  def initialize",
      "  def preview_class; FontPreview; end\n\n  def initialize"));
    fs.writeFileSync(path.join(project, "lib/FontPreview.rb"), `
class FontPreview
  @tag_name = "font-preview"

  def html
    %q{<span class="sample">Preview</span>}
  end

  def css
    %q{.sample { font-family: PreviewSans, sans-serif; line-height: 24px; }}
  end
end
`);
    const previewFont = path.join(__dirname, "../../devground/public/fonts/noto-sans/static/NotoSans-Regular.ttf");
    fs.copyFileSync(previewFont, path.join(project, "public/preview.ttf"));
    const config = path.join(project, "mochi-portable.json");
    const declaration = JSON.parse(fs.readFileSync(config, "utf8"));
    declaration.fonts.PreviewSans = { "400": { file: "public/preview.ttf", license: "public/OFL.txt" } };
    fs.writeFileSync(config, JSON.stringify(declaration));

    await withCompiledProject(project, async (url, bundle) => {
      const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
      const resources = Object.values(manifest.resources) as { kind: string; file: string }[];
      const preview = resources.find(resource => resource.kind === "font" && resource.file.endsWith(".ttf"))!;
      const requests: string[] = [];
      page.on("request", request => requests.push(new URL(request.url()).pathname));
      await page.goto(url);
      await expect(page.locator("record-inspector .title")).toHaveText("Station records Ω");
      await page.evaluate(() => document.fonts.ready.then(() => undefined));
      expect(requests).not.toContain("/" + preview.file);

      await page.evaluate(() => document.body.append(document.createElement("font-preview")));
      const label = page.locator("font-preview .sample");
      await expect(label).toHaveText("Preview");
      await label.evaluate(async element => {
        const style = getComputedStyle(element);
        await document.fonts.load(`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`, "Preview");
      });
      expect(requests.filter(path => path === "/" + preview.file)).toHaveLength(1);
    });
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
