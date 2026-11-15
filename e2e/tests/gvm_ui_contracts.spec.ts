import { test, expect, type Page, type TestInfo } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withCompiledProject, runRubyProject } from "./framework_helpers";

const repoRoot = path.resolve(__dirname, "../..");
const compiler = path.join(repoRoot, "compiler/mochi");
const fixture = path.join(__dirname, "../fixtures/ui_contracts");

test("downloads stay optional, preserve binary bytes, and retain accepted URLs through disposal @ui-inspector", async ({ page }) => {
  await withCompiledProject(path.join(repoRoot, "compiler/spec/fixtures/payload/minimal"), async (_url, bundle) => {
    const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
    expect(manifest.capabilities?.download).toBeUndefined();
    expect(fs.existsSync(path.join(bundle, "mochi-download.js"))).toBe(false);
    expect(Object.keys(manifest.packages).some(key => key.includes("builtin_download"))).toBe(false);
  });
  await page.clock.install();
  await page.addInitScript(() => {
    const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    const urls = new Set<string>();
    (window as any).__downloadUrls = urls;
    (window as any).__downloadTypes = [];
    URL.createObjectURL = blob => {
      const url = create(blob); urls.add(url);
      (window as any).__downloadTypes.push((blob as Blob).type);
      return url;
    };
    URL.revokeObjectURL = url => { urls.delete(url); revoke(url); };
  });
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  let releaseAdapter!: () => void, requestedAdapter!: () => void;
  const ready = new Promise<void>(resolve => { releaseAdapter = resolve; });
  const requested = new Promise<void>(resolve => { requestedAdapter = resolve; });
  await page.route("**/mochi-download.js", async route => {
    requestedAdapter(); await ready; await route.continue();
  });
  await withCompiledProject(path.join(fixture, "probes/14-download"), async url => {
    const navigation = page.goto(url);
    await requested;
    try { await expect(page.locator(".save")).toHaveCount(0); }
    finally { releaseAdapter(); }
    await navigation;
    await expect(page.locator("output")).toHaveText("idle");
    await page.locator(".oversized").click();
    const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
    expect(errors).toHaveLength(1);
    expect(errors[0].vmText).toContain("byte limit");
    const lines = fs.readFileSync(path.join(fixture, "probes/14-download/lib/ProbeRoot.rb"), "utf8").split("\n");
    expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def oversized") + 1}`);
    await settleConsole();
    for (const error of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) expect(error).toContain("byte limit");
    expect(await page.evaluate(() => (window as any).__downloadUrls.size)).toBe(0);
    for (let index = 0; index < 3; index++) {
      const pending = page.waitForEvent("download");
      await page.locator(index === 1 ? ".save-string" : ".save").click();
      const download = await pending;
      // WebKit/macOS returns canonically equivalent decomposed filenames.
      expect(download.suggestedFilename().normalize("NFC")).toBe("résumé.bin");
      expect([...fs.readFileSync((await download.path())!)]).toEqual([0, 128, 255]);
      await download.delete();
    }
    expect(await page.evaluate(() => (window as any).__downloadTypes)).toEqual(Array(3).fill("application/octet-stream"));
    await page.locator("probe-root").evaluate(element => element.remove());
    expect(await page.evaluate(() => (window as any).__downloadUrls.size)).toBe(3);
    await page.clock.fastForward(30001);
    expect(await page.evaluate(() => (window as any).__downloadUrls.size)).toBe(0);
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
  }, "<probe-root></probe-root>");
});

test("download startup failures retain lifecycle source despite helper name collisions @ui-inspector", async ({ page }) => {
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  for (const lifecycle of ["initialize", "mounted"]) {
    const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-download-source-"));
    try {
      fs.cpSync(path.join(fixture, "probes/14-download"), project, {recursive: true});
      const source = path.join(project, "lib/ProbeRoot.rb");
      const invalid = '    MochiDownload.save("", "text/plain", "x")\n';
      const original = fs.readFileSync(source, "utf8");
      const modified = lifecycle === "initialize"
        ? original.replace("  def initialize\n", "  def initialize\n" + invalid)
        : original.replace("  def save\n", "  def mounted\n" + invalid + "  end\n\n  def save\n");
      fs.writeFileSync(source, modified);
      await withCompiledProject(project, async url => {
        await page.goto(url);
        await expect.poll(() => page.evaluate(() => (window as any).__uiErrors.length)).toBe(1);
        const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
        expect(errors[0].method).toBe(lifecycle);
        expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${modified.split("\n").indexOf(`  def ${lifecycle}`) + 1}`);
        if (lifecycle === "mounted") expect(errors[0].message).toContain("MochiDownload#save");
        expect(errors[0].message).toContain("metadata limits");
        await expect(page.locator("probe-root .save")).toHaveCount(0);
        await settleConsole();
        for (const error of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) expect(error).toContain("metadata limits");
      }, "<probe-root></probe-root>");
    } finally { fs.rmSync(project, {recursive: true, force: true}); }
  }
});

test("Ruby timestamp conversions and error recovery @ui-inspector", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/09-time"), browserName);
  expect(output).toContain(`PASS [${browserName}] Unix seconds preserve fractions`);
  expect(output).toContain(`PASS [${browserName}] unsupported time forms`);
});

test("clock and formatting stay optional; fixed wall clock uses seconds @ui-inspector", async ({ page }) => {
  await withCompiledProject(path.join(repoRoot, "compiler/spec/fixtures/payload/minimal"), async (_url, bundle) => {
    const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
    for (const capability of ["time", "formatting"]) expect(manifest.capabilities?.[capability]).toBeUndefined();
    for (const file of ["mochi-time.js", "mochi-format.js"]) expect(fs.existsSync(path.join(bundle, file))).toBe(false);
    expect(Object.keys(manifest.packages).some(key => /builtin_(time|format)\.rb/.test(key))).toBe(false);
  });
  await page.clock.setFixedTime(new Date(1794571200123));
  const requests: string[] = [];
  page.on("request", request => requests.push(request.url()));
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(path.join(fixture, "probes/09-time"), async url => {
    await page.goto(url);
    await expect(page.locator(".now")).toHaveText("");
    await expect(page.locator("output")).toHaveText("-1.25:-2:true");
    await page.locator(".now-button").click();
    await expect(page.locator(".now")).toHaveText("1794571200.123:1794571200");
    await page.clock.setFixedTime(new Date(-1250));
    await page.locator(".now-button").click();
    await expect(page.locator(".now")).toHaveText("-1.25:-2");
    await page.locator(".wrong-type").click();
    const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
    expect(errors).toHaveLength(1);
    const lines = fs.readFileSync(path.join(fixture, "probes/09-time/lib/ProbeRoot.rb"), "utf8").split("\n");
    expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def wrong_type") + 1}`);
    expect(errors[0].vmText).toContain("Time.at expects Integer or Float Unix seconds");
    await settleConsole();
    for (const error of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
      expect(error).toContain("Time.at expects Integer or Float Unix seconds");
    }
    await page.locator(".valid").click();
    await expect(page.locator("output")).toHaveText("-1.25:-2:true");
    for (let index = 0; index < 3; index++) {
      await page.locator("probe-root").evaluate(element => element.replaceWith(document.createElement("probe-root")));
      await page.locator(".now-button").click();
      await expect(page.locator(".now")).toHaveText("-1.25:-2");
    }
    expect(requests.filter(request => request.endsWith("/mochi-time.js"))).toHaveLength(1);
    expect(requests.filter(request => request.endsWith("/mochi-format.js"))).toHaveLength(1);
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
  }, "<clock-root></clock-root><probe-root></probe-root>");
});

test("JSON errors recover through ordinary Ruby calls @ui-inspector", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/09-json"), browserName);
  expect(output).toContain(`PASS [${browserName}] JSON rejects invalid values`);
});

test("JSON stays optional and failures retain source locations @ui-inspector", async ({ page }) => {
  await withCompiledProject(path.join(repoRoot, "compiler/spec/fixtures/payload/minimal"), async (_url, bundle) => {
    const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
    expect(Object.keys(manifest.packages).some(key => key.includes("builtin_json"))).toBe(false);
    expect(fs.existsSync(path.join(bundle, "mochi-json.js"))).toBe(false);
  });
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(path.join(fixture, "probes/09-json"), async url => {
    await page.goto(url);
    await expect(page.locator("output")).toHaveText('{"id":9007199254740993}');
    await page.locator(".malformed").click();
    const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
    expect(errors).toHaveLength(1);
    expect(errors[0].message).toContain("invalid JSON or UTF-8");
    const lines = fs.readFileSync(path.join(fixture, "probes/09-json/lib/ProbeRoot.rb"), "utf8").split("\n");
    expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def malformed") + 1}`);
    expect(errors[0].method).toBe("malformed");
    expect(errors[0].vmText).toContain("JSON#parse");
    await settleConsole();
    for (const diagnostic of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
      expect(diagnostic).toContain("invalid JSON or UTF-8");
    }
    await page.locator(".valid").click();
    await expect(page.locator(".computed")).toHaveText('{"id":9007199254740993}');
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
  }, "<probe-root></probe-root>");
});

test("active form shortcut scope suppresses graph actions and restores focus @ui-graph @ui-form", async ({ page }) => {
  const errors: string[] = []; page.on("pageerror", error => errors.push(error.message));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const graph = page.locator("editable-graph-root"), form = page.locator("nested-form-root");
    await expect(graph.locator(".node")).toHaveCount(4);
    await expect(form.locator(".closed")).toHaveText("Form closed");
    await graph.locator(".move").click(); await graph.locator(".move").click();
    await graph.locator(".viewport").focus(); await page.keyboard.press("Control+z");
    await expect(graph.locator(".undo-count")).toHaveText("1");
    await page.keyboard.press("Control+Shift+z");
    await expect(graph.locator(".undo-count")).toHaveText("2");
    await page.evaluate(() => {
      (window as any).__keyPrevention = [];
      document.addEventListener("keydown", event => (window as any).__keyPrevention.push(event.defaultPrevented));
    });
    await graph.locator(".graph-note").fill("Keep ordinary editing");
    await page.keyboard.press("Control+z"); await page.keyboard.press("Meta+z");
    await expect(graph.locator(".undo-count")).toHaveText("2");
    expect(await page.evaluate(() => (window as any).__keyPrevention.some(Boolean))).toBe(false);
    for (let index = 0; index < 3; index++) {
      await form.locator(".toggle").focus(); await page.keyboard.press("Enter");
      await expect(form.locator(".dialog")).toBeFocused();
      // Even forced focus outside a modal owner cannot activate lower scopes.
      await graph.locator(".viewport").focus(); await page.keyboard.press("Control+z");
      await expect(graph.locator(".undo-count")).toHaveText("2");
      const draft = form.locator("[data-field='a'] field-editor .draft");
      await draft.fill("Discard this draft"); await page.keyboard.press("Escape");
      await expect(form.locator(".closed")).toHaveText("Form closed");
      await expect(form.locator(".toggle")).toBeFocused();
      await page.keyboard.press("Escape"); // cancellation removed its registration
      await expect(form.locator(".toggle")).toBeFocused();
    }
    await graph.locator(".viewport").focus(); await page.keyboard.press("Control+z");
    await expect(graph.locator(".undo-count")).toHaveText("1");
    // Parent/attribute-driven branches must own the same shortcut lifetime.
    await form.evaluate(el => el.setAttribute("open", "true"));
    await expect(form.locator(".dialog")).toBeVisible();
    await graph.locator(".viewport").focus(); await page.keyboard.press("Control+z");
    await expect(graph.locator(".undo-count")).toHaveText("1");
    await form.evaluate(el => el.setAttribute("open", "false"));
    await expect(form.locator(".closed")).toHaveText("Form closed");
    await page.keyboard.press("Control+z");
    await expect(graph.locator(".undo-count")).toHaveText("0");
    await form.evaluate(el => el.setAttribute("open", "true"));
    await expect(form.locator(".dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(form.locator(".closed")).toHaveText("Form closed");
    await expect(graph.locator(".shortcut-error")).toHaveText("");
    await expect(form.locator(".shortcut-error")).toHaveText("");
    expect(errors).toEqual([]);
  }, '<editable-graph-root></editable-graph-root><nested-form-root open="false"></nested-form-root>');
});

test("shortcuts stay optional and remounts retain one owned action @ui-graph @ui-form", async ({ page }) => {
  await withCompiledProject(path.join(repoRoot, "compiler/spec/fixtures/payload/minimal"), async (_url, bundle) => {
    expect(fs.existsSync(path.join(bundle, "mochi-shortcuts.js"))).toBe(false);
    const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
    expect(manifest.capabilities?.shortcuts).toBeUndefined();
    expect(Object.keys(manifest.packages).some(key => key.includes("builtin_shortcuts"))).toBe(false);
  });
  const requests: string[] = []; page.on("request", request => requests.push(request.url()));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator("inspector-root .total")).toHaveText("480");
    expect(requests.filter(url => url.endsWith("/mochi-shortcuts.js"))).toHaveLength(0);
    await page.evaluate(() => { (window as any).__graph = document.createElement("editable-graph-root"); });
    for (let index = 0; index < 3; index++) {
      await page.evaluate(() => document.body.appendChild((window as any).__graph));
      const graph = page.locator("editable-graph-root");
      await expect(graph.locator(".node")).toHaveCount(4);
      await graph.locator(".move").click(); await graph.locator(".move").click();
      await graph.locator(".viewport").focus(); await page.keyboard.press("Control+z");
      await expect(graph.locator(".undo-count")).toHaveText("1");
      await expect(graph.locator(".redo-count")).toHaveText("1");
      await graph.evaluate(el => el.remove());
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(resolve)));
      await page.keyboard.press("Control+z");
    }
    expect(requests.filter(url => url.endsWith("/mochi-shortcuts.js"))).toHaveLength(1);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().pendingHostRequests)).toBe(0);
  }, "<inspector-root></inspector-root>");
});

test("wheel zoom preserves measured pointer anchor, units, limits, and drag @ui-graph", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator("editable-graph-root");
    await expect(root.locator(".node")).toHaveCount(4);
    const state = () => root.evaluate(el => {
      const scene = el.shadowRoot!.querySelector(".scene") as SVGGElement;
      const scaled = el.shadowRoot!.querySelector(".scaled") as SVGGElement;
      const matrix = scaled.getScreenCTM()!;
      return { scale: scaled.transform.baseVal.getItem(0).matrix.a,
        x: scene.transform.baseVal.getItem(0).matrix.e, y: scene.transform.baseVal.getItem(0).matrix.f,
        a: matrix.a, d: matrix.d, e: matrix.e, f: matrix.f };
    });
    const wheel = async (mode: number, delta: number, x: number, y: number) => {
      const before = await state();
      const model = { x: (x - before.e) / before.a, y: (y - before.f) / before.d };
      await root.locator(".canvas").dispatchEvent("wheel", { deltaMode: mode, deltaY: delta, clientX: x, clientY: y, cancelable: true });
      await expect.poll(async () => (await state()).scale).not.toBe(before.scale);
      const after = await state();
      expect(Math.abs(model.x * after.a + after.e - x)).toBeLessThan(0.02);
      expect(Math.abs(model.y * after.d + after.f - y)).toBeLessThan(0.02);
      return after.scale;
    };
    const viewport = await root.locator(".viewport").boundingBox();
    const x = Math.floor(viewport!.x + 150), y = Math.floor(viewport!.y + 80);
    expect(await wheel(0, 16, x, y)).toBeCloseTo(0.968, 5);
    expect(await wheel(1, -1, x, y)).toBeCloseTo(1, 5);
    expect(await wheel(2, 0.5, x, y)).toBeCloseTo(0.78, 5);
    expect(await wheel(0, -110, x, y)).toBeCloseTo(1, 5);

    // Mixed-mode burst uses one geometry read and the last pointer anchor.
    const before = await state();
    await root.locator(".canvas").evaluate((canvas, anchor) => {
      const viewport = canvas.parentElement!;
      const read = viewport.getBoundingClientRect.bind(viewport);
      (window as any).__wheelReads = 0;
      viewport.getBoundingClientRect = () => { (window as any).__wheelReads++; return read(); };
      for (let index = 0; index < 20; index++) canvas.dispatchEvent(new WheelEvent("wheel", {
        bubbles: true, cancelable: true, deltaY: 1, deltaMode: index % 2, clientX: anchor.x - 30 + index, clientY: anchor.y
      }));
    }, { x, y });
    await expect.poll(async () => (await state()).scale).toBeCloseTo(0.66, 5);
    const burst = await state(), anchorX = x - 11;
    expect(Math.abs((anchorX - before.e) / before.a * burst.a + burst.e - anchorX)).toBeLessThan(0.02);
    expect(await page.evaluate(() => (window as any).__wheelReads)).toBe(1);
    expect(await wheel(0, 10000, x, y)).toBeCloseTo(0.25, 5);
    expect(await wheel(0, -10000, x, y)).toBeCloseTo(4, 5);
    await wheel(0, 1500, x, y); // back to scale 1

    const node = root.locator("[data-node='b'] circle");
    const start = await node.boundingBox();
    const startViewport = await root.locator(".viewport").boundingBox();
    await page.mouse.move(start!.x + start!.width / 2, start!.y + start!.height / 2);
    // A new drag wins over a zoom whose geometry read is still pending.
    await page.evaluate(() => {
      const original = requestAnimationFrame, cancel = cancelAnimationFrame;
      const pending = new Map<number, FrameRequestCallback>(); let next = 1000000;
      (window as any).__heldFrames = pending;
      (window as any).__restoreFrames = () => { window.requestAnimationFrame = original; window.cancelAnimationFrame = cancel; };
      window.requestAnimationFrame = callback => { pending.set(++next, callback); return next; };
      window.cancelAnimationFrame = id => { if (!pending.delete(id)) cancel(id); };
    });
    await root.locator(".canvas").dispatchEvent("wheel", { deltaY: 100, clientX: x, clientY: y });
    await page.evaluate(() => {
      const pending = (window as any).__heldFrames as Map<number, FrameRequestCallback>;
      const callbacks = [...pending.values()]; pending.clear(); callbacks.forEach(fn => fn(performance.now()));
    }); // wheel handler now waits for its layout frame
    await page.mouse.down();
    await page.evaluate(() => {
      (window as any).__restoreFrames();
      const pending = (window as any).__heldFrames as Map<number, FrameRequestCallback>;
      const callbacks = [...pending.values()]; pending.clear(); callbacks.forEach(fn => fn(performance.now()));
    });
    expect((await state()).scale).toBeCloseTo(1, 5);
    await page.mouse.move(start!.x + start!.width / 2 + 20, start!.y + start!.height / 2 + 10); await page.mouse.up();

    const end = await node.boundingBox(), endViewport = await root.locator(".viewport").boundingBox();
    expect(end!.x - start!.x).toBeCloseTo(20, 0);
    expect((end!.y - endViewport!.y) - (start!.y - startViewport!.y)).toBeCloseTo(10, 0);
    await expect(root.locator(".undo-count")).toHaveText("1");
    expect(errors).toEqual([]);
  }, "<editable-graph-root></editable-graph-root>");
});

test("wheel prevention is confined to graph and anchor follows page scrolling @ui-graph", async ({ page }) => {
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator("editable-graph-root");
    await expect(root.locator(".node")).toHaveCount(4);
    await root.evaluate(async el => { await (el as any)._mochiReady; });
    await page.evaluate(() => scrollTo(0, 200));
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const bounds = await root.locator(".viewport").boundingBox();
    const x = Math.floor(bounds!.x + 120), y = Math.floor(bounds!.y + 70);
    const modelPoint = () => root.locator(".scaled").evaluate((el, p) => {
      const m = (el as SVGGraphicsElement).getScreenCTM()!;
      return { x: (p.x - m.e) / m.a, y: (p.y - m.f) / m.d };
    }, { x, y });
    const before = await modelPoint(), scroll = await page.evaluate(() => scrollY);
    await page.mouse.move(x, y); await page.mouse.wheel(0, 50);

    await expect(root.locator(".layout-status")).toHaveText("zoomed");
    const after = await modelPoint();
    expect(after.x).toBeCloseTo(before.x, 2); expect(after.y).toBeCloseTo(before.y, 2);
    expect(await page.evaluate(() => scrollY)).toBe(scroll);
    await page.mouse.move(900, 300); await page.mouse.wheel(0, 200);
    await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(scroll);
  }, '<div style="height:300px">before</div><editable-graph-root></editable-graph-root><div style="height:2000px">outside</div>');
});

test("optional layout fits real resized graph bounds and stops observation @ui-graph", async ({ page }) => {
  const failures: string[] = [];
  page.on("pageerror", error => failures.push(error.message));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator("editable-graph-root");
    await expect(root.locator(".layout-status")).toHaveText("ready");
    await root.locator(".fit").click();
    await expect(root.locator(".layout-status")).toHaveText("fitted");
    const contained = () => root.evaluate(el => {
      const shadow = el.shadowRoot!;
      const viewport = shadow.querySelector(".viewport")!.getBoundingClientRect();
      return [...shadow.querySelectorAll(".node")].every(node => {
        const bounds = node.getBoundingClientRect();
        return bounds.left >= viewport.left + 23 && bounds.top >= viewport.top + 23 &&
          bounds.right <= viewport.right - 23 && bounds.bottom <= viewport.bottom - 23;
      });
    });
    expect(await contained()).toBe(true);
    for (const [width, height] of [[640, 360], [280, 180]]) {
      await root.locator(".viewport").evaluate((el, size) => {
        (el as HTMLElement).style.width = `${size[0]}px`;
        (el as HTMLElement).style.height = `${size[1]}px`;
      }, [width, height]);
      await expect.poll(() => root.locator(".canvas").getAttribute("viewBox")).toMatch(new RegExp(`^0 0 ${width}(?:\\.0)? ${height}(?:\\.0)?$`));
      await expect.poll(contained).toBe(true);
    }
    // Fit scale must also be inverted for captured pointer movement.
    const node = root.locator("[data-node='b'] circle");
    const beforeViewport = await root.locator(".viewport").boundingBox();
    const before = await node.boundingBox();
    await page.mouse.move(before!.x + before!.width / 2, before!.y + before!.height / 2);
    await page.mouse.down(); await page.mouse.move(before!.x + before!.width / 2 + 15, before!.y + before!.height / 2 + 10);
    await page.mouse.up();
    const after = await node.boundingBox();
    expect(after!.x - before!.x).toBeCloseTo(15, 0);
    const afterViewport = await root.locator(".viewport").boundingBox();
    expect((after!.y - afterViewport!.y) - (before!.y - beforeViewport!.y)).toBeCloseTo(10, 0);
    await root.locator(".undo").click();
    await expect.poll(contained).toBe(true);

    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.width = "40px"; });
    await expect(root.locator(".layout-status")).toHaveText("too small");
    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.width = "0px"; });
    await expect(root.locator(".layout-status")).toHaveText("hidden");
    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.width = "280px"; });
    await expect(root.locator(".layout-status")).toHaveText("fitted");
    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.display = "none"; });

    await expect(root.locator(".layout-status")).toHaveText("hidden");
    expect(await root.locator(".scene").getAttribute("transform")).not.toMatch(/NaN|Infinity/);
    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.display = "block"; });
    await expect(root.locator(".layout-status")).toHaveText("fitted");
    await root.locator(".stop-layout").click();
    await expect(root.locator(".layout-status")).toHaveText("stopped");
    const stopped = await root.locator(".canvas").getAttribute("viewBox");
    await root.locator(".viewport").evaluate(el => { (el as HTMLElement).style.width = "350px"; });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    expect(await root.locator(".canvas").getAttribute("viewBox")).toBe(stopped);
    await root.locator(".fit").click(); // one-shot measurement still works
    await expect(root.locator(".layout-status")).toHaveText("fitted");
    for (const id of ["a", "b", "c", "d"]) {
      await root.locator(`[data-node='${id}']`).dispatchEvent("click");
      await root.locator(".remove-node").click();
    }
    await root.locator(".fit").click();
    await expect(root.locator(".layout-status")).toHaveText("empty");
    expect(await root.locator(".scaled").getAttribute("transform")).toBe("scale(1)");
    expect(failures).toEqual([]);
  }, "<editable-graph-root></editable-graph-root>");
});

test("layout package is absent when unused and adapter loads only for graph mount @ui-graph", async ({ page }) => {
  await withCompiledProject(path.join(repoRoot, "compiler/spec/fixtures/payload/minimal"), async (_url, bundle) => {
    expect(fs.existsSync(path.join(bundle, "mochi-layout.js"))).toBe(false);
    const manifest = JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8"));
    expect(manifest.capabilities?.layout).toBeUndefined();
    expect(Object.keys(manifest.packages).some(key => key.includes("builtin_layout"))).toBe(false);
  });
  const requests: string[] = [];
  page.on("request", request => requests.push(request.url()));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator("inspector-root .total")).toHaveText("480");
    expect(requests.filter(url => url.endsWith("/mochi-layout.js"))).toHaveLength(0);
    for (let index = 0; index < 3; index++) {
      await page.evaluate(() => document.body.appendChild(document.createElement("editable-graph-root")));
      await expect(page.locator("editable-graph-root .layout-status")).toHaveText("ready");
      await page.locator("editable-graph-root .fit").click();
      await expect(page.locator("editable-graph-root .layout-status")).toHaveText("fitted");
      await page.locator("editable-graph-root").evaluate(el => el.remove());
    }
    expect(requests.filter(url => url.endsWith("/mochi-layout.js"))).toHaveLength(1);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().pendingHostRequests)).toBe(0);
  }, "<inspector-root></inspector-root>");
});

test("inspector renders exactly 12 of 480 records without browser errors @ui-inspector", async ({ page }, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await page.addInitScript(() => {
    (window as any).__uiErrors = [];
    document.addEventListener("mochi:error", event => (window as any).__uiErrors.push((event as CustomEvent).detail));
  });
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    await expect(page.locator("inspector-root .record")).toHaveCount(12);
    await expect(page.locator("inspector-root .total")).toHaveText("480");
    await expect(page.locator("inspector-root .record").first()).toHaveAttribute("data-id", "record-1");
    await expect(page.locator("inspector-root .record").last()).toHaveAttribute("data-id", "record-12");
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    expect(errors).toEqual([]);
  });
});

// Discover every authored Ruby suite. Graph/form stories add their files to
// this same project; these entry points then include them without new harnesses.
const rubySuites: Record<string, string> = {
  "download_test.rb": "@ui-inspector",
  "inspector_test.rb": "@ui-inspector",
  "editable_graph_test.rb": "@ui-graph",
  "dialog_test.rb": "@ui-form",
  "nested_form_test.rb": "@ui-form",
  "binding_actions_test.rb": "@ui-form",
};
for (const file of fs.readdirSync(path.join(fixture, "test"), { recursive: true }).map(String).sort()
  .filter(file => file.endsWith("_test.rb"))) {
  test(`Ruby-authored UI scenarios: ${file} ${rubySuites[file] || "@ui"}`, async ({ browserName }) => {
    test.setTimeout(240_000);
    const output = runRubyProject(fixture, browserName, file);
    expect(output).toContain(`PASS [${browserName}]`);
  });
}

function probeTarget(name: string): string {
  if (/^(01|05|07|11)-/.test(name)) return "@ui-form";
  if (/^06-/.test(name) || name === "09-wheel") return "@ui-graph";
  return "@ui-inspector";
}

test("Ruby array slice contracts across contexts and failure recovery @ui-inspector", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/02-array-contexts"), browserName);
  expect(output).toContain(`PASS [${browserName}] array slices match Ruby`);
  expect(output).toContain(`PASS [${browserName}] invalid array arguments`);
  expect(output).toContain(`PASS [${browserName}] slice exhaustion`);
});

test("Ruby helper receivers, constants, and block next across contexts @ui-inspector", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/03-helper-contexts"), browserName);
  expect(output).toContain(`PASS [${browserName}] helper constants, receivers, and next`);
  expect(output).toContain(`PASS [${browserName}] missing helper references`);
});

test("missing helper references retain authored source and receiver @ui-inspector", async ({ page }) => {
  const source = path.join(fixture, "probes/03-helper-contexts");
  const lines = fs.readFileSync(path.join(source, "lib/ProbeRoot.rb"), "utf8").split("\n");
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(source, async baseURL => {
    await page.goto(baseURL);
    await expect(page.locator(".initial")).toHaveText("1794571200000:1794571200000");
    for (const [selector, method, message] of [
      [".missing-constant", "missing_constant", "unknown constant RecordData::MISSING"],
      [".missing-method", "missing_method", "RecordData#missing: unknown method"],
    ]) {
      await page.locator(selector).click();
      const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
      expect(errors).toHaveLength(1);
      expect(errors[0].message).toContain(message);
      expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf(`  def ${method}`) + 1}`);
      await settleConsole();
      for (const diagnostic of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
        expect(diagnostic).toContain(message);
      }
    }
    await page.locator(".update").click();
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<probe-root></probe-root>");
});

test("array errors retain authored methods, source lines, and capacity details @ui-inspector", async ({ page }, testInfo) => {
  const source = path.join(fixture, "probes/02-array-contexts");
  const lines = fs.readFileSync(path.join(source, "lib/ProbeRoot.rb"), "utf8").split("\n");
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(source, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, source, bundle);
    await page.goto(baseURL);
    const root = page.locator("probe-root");
    await expect(root.locator(".initial")).toHaveText("2,3");
    await root.locator(".prepare-big").click();
    await expect(root.locator(".big-count")).toHaveText("5000");
    for (const [selector, method, message] of [
      [".no-args", "no_args", "wrong number of arguments"],
      [".extra-args", "extra_args", "wrong number of arguments"],
      [".bad-start", "bad_start", "type mismatch"],
      [".bad-length", "bad_length", "type mismatch"],
      [".bad-scalar", "bad_scalar", "type mismatch"],
      [".exhaust", "exhaust_slice", "scratch slots exhausted"],
    ]) {
      await root.locator(selector).click();
      const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
      expect(errors).toHaveLength(1);
      expect(errors[0].message).toContain(message);
      expect(errors[0].method).toBe(method);
      expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf(`  def ${method}`) + 1}`);
      if (method === "exhaust_slice") {
        expect(errors[0].message).toMatch(/requested 5000, used \d+ of 4096/);
        await expect(root.locator(".last")).toHaveText("unchanged");
      }
      await settleConsole();
      for (const diagnostic of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
        expect(diagnostic).toContain(message);
      }
    }
    await root.locator(".small").click();
    await expect(root.locator(".last")).toHaveText("4998,4999");
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<probe-root></probe-root>");
});

// These are evidence assertions, not acceptance claims for the owning stories.
// A repaired defect must replace its observed-failure assertion with the Ruby
// oracle in UI_FIXTURE_CONTRACTS.md; never skip the reproducer.
const compileFailures: Record<string, { message: string; owner: string }> = {
  "03-unsupported-rescue": { message: "lib/ProbeRoot.rb:6: unsupported rescue/ensure (OP_EXCEPT)", owner: "E1.S3 unsupported control flow" },
  "10-redo": { message: 'unsupported redo in template expression "redo"', owner: "intentional Ruby keyword; E1.S3" },
  "12-root-css": { message: 'CSS import "../../styles/base.css"', owner: "E7.S2" },
  "12-missing-css": { message: 'CSS import "missing.css"', owner: "intentional missing-file error; E7.S2" },
};
const mountFailures: Record<string, { message: string; owner: string }> = {
  "09-math": { message: "ProbeRoot#initialize: unknown class", owner: "deferred Math" },
  "09-regexp": { message: "ProbeRoot#initialize: unknown class", owner: "deferred Regexp" },
};
const textProbes: Record<string, { selector: string; text: string; count?: number; owner: string }> = {
  "09-time": { selector: "output", text: "-1.25:-2:true", owner: "E6.S2" },
  "09-json": { selector: "output", text: '{"id":9007199254740993}', owner: "E6.S1" },
  "01-if-in-each": { selector: "tbody tr.selected td", text: "Alpha", owner: "E2.S1" },
  "01-each-in-if": { selector: "div", text: "Alpha", owner: "E2.S1" },
  "01-nested-each": { selector: "section p", text: "Alpha", owner: "E2.S1" },
  "02-brackets": { selector: ".items", text: "2:2,3", owner: "E1.S2" },
  "02-slice": { selector: ".items", text: "2:2,3", owner: "E1.S2" },
  "03-singleton": { selector: "output", text: "1794571200000", owner: "E1.S3" },
  "03-constant": { selector: "output", text: "1794571200000", owner: "E1.S3" },
  "04-structured-records": { selector: "output", text: "480", owner: "E4.S1–E4.S3" },
  "04-concatenation": { selector: "output", text: "24370", owner: "E4.S1–E4.S3" },
  "04-repeated-split": { selector: "output", text: "480", count: 20, owner: "E4.S1–E4.S3" },
  "05-attribute-quotes": { selector: 'div.ghost[aria-label="Open record"]', text: "Open record", owner: "E2.S2" },
  "05-conditional-quotes": { selector: "div.ghost", text: "Open record", owner: "E2.S2" },
  "10-next": { selector: "output", text: "alpha,beta", owner: "E1.S3" },
  "11-boolean": { selector: "output", text: "false", owner: "E2.S4" },
};

function sha256(file: string): string {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

async function attachArtifacts(testInfo: TestInfo, source: string, bundle?: string) {
  const hashes = (directory: string) => Object.fromEntries(
    fs.readdirSync(directory, { recursive: true }).map(String).sort()
      .filter(file => fs.statSync(path.join(directory, file)).isFile())
      .map(file => [file, sha256(path.join(directory, file))]));
  await testInfo.attach("artifact-identity", {
    body: JSON.stringify({ compiler: sha256(compiler), source: hashes(source),
      bundle: bundle ? hashes(bundle) : null,
      manifest: bundle ? JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8")) : null }, null, 2),
    contentType: "application/json",
  });
}

async function captureErrors(page: Page) {
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];
  const consoleDetails: Promise<void>[] = [];
  page.on("console", message => {
    if (message.type() !== "error") return;
    const index = consoleErrors.push(message.text()) - 1;
    // Firefox's text() prints only "Error" for console Error objects. Read
    // their messages so negative probes still reject unrelated diagnostics.
    consoleDetails.push(Promise.all(message.args().map(argument =>
      argument.evaluate(value => value instanceof Error ? value.message : "")))
      .then(details => { consoleErrors[index] += details.filter(Boolean).join(" "); }));
  });
  page.on("pageerror", error => pageErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__uiErrors = [];
    document.addEventListener("mochi:error", event => (window as any).__uiErrors.push((event as CustomEvent).detail));
  });
  return { consoleErrors, pageErrors, settleConsole: () => Promise.all(consoleDetails) };
}

for (const [name, failure] of Object.entries(compileFailures)) {
  test(`feedback evidence ${name}: compiler diagnostic ${probeTarget(name)}`, async ({}, testInfo) => {
    testInfo.annotations.push({ type: "owner", description: failure.owner });
    const source = path.join(fixture, "probes", name);
    await attachArtifacts(testInfo, source);
    let diagnostic = "";
    try {
      await withCompiledProject(source, async () => {}, "<probe-root></probe-root>");
    } catch (error: any) {
      expect(error.status).toBe(1);
      diagnostic = error.stderr.toString();
    }
    expect(diagnostic).toContain(failure.message);
    expect(diagnostic).toMatch(/lib\/(?:nested\/)?ProbeRoot\.rb:\d+/);
    if (name.startsWith("12-")) expect(diagnostic).toContain("was not found");
    await testInfo.attach("compiler-diagnostic", { body: diagnostic, contentType: "text/plain" });
  });
}

const runtimeProbes = [...Object.keys(mountFailures), ...Object.keys(textProbes),
  "06-svg-each", "07-binding-handler", "08-event-dataset", "09-wheel", "12-assets-css"];
for (const name of runtimeProbes) {
  test(`feedback evidence ${name}: runtime observation ${probeTarget(name)}`, async ({ page, browserName }, testInfo) => {
    const failure = mountFailures[name];
    const textProbe = textProbes[name];
    testInfo.annotations.push({ type: "owner", description: failure?.owner || textProbe?.owner ||
      ({ "06-svg-each": "E3.S1", "07-binding-handler": "E2.S3", "08-event-dataset": "E3.S2",
         "09-wheel": "E5.S2", "12-assets-css": "E7.S2" } as Record<string, string>)[name] });
    const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
    const source = path.join(fixture, "probes", name);
    await withCompiledProject(source, async (baseURL, bundle) => {
      await attachArtifacts(testInfo, source, bundle);
      await page.goto(baseURL);
      await page.waitForFunction(() => !!(document.querySelector("probe-root") as any)?._mochiReady);
      const mountError = await page.evaluate(async () => {
        try { await (document.querySelector("probe-root") as any)._mochiReady; return null; }
        catch (error: any) { return error.message; }
      });
      if (failure) {
        expect(mountError).toContain(failure.message);
        expect(mountError).toMatch(/lib\/ProbeRoot\.rb:\d+/);
        const runtimeErrors = await page.evaluate(() => (window as any).__uiErrors);
        expect(runtimeErrors).toHaveLength(1);
        expect(runtimeErrors[0].message).toContain(failure.message);
        await settleConsole();
        for (const message of [...consoleErrors, ...pageErrors]) expect(message).toContain(failure.message);
        await testInfo.attach("mount-diagnostic", {
          body: JSON.stringify({ mountError, runtimeErrors, consoleErrors, pageErrors }, null, 2), contentType: "application/json",
        });
        return;
      }
      expect(mountError).toBeNull();
      const root = page.locator("probe-root");
      if (textProbe) {
        const nodes = root.locator(textProbe.selector);
        await expect(nodes).toHaveText(Array(textProbe.count || 1).fill(textProbe.text));
      } else if (name === "06-svg-each") {
        const paths = root.locator("path");
        await expect(paths).toHaveCount(2);
        await expect(paths.nth(0)).toHaveAttribute("d", "M 0 0 L 20 20");
        await expect(paths.nth(1)).toHaveAttribute("d", "M 20 20 L 40 0");
        expect(await paths.evaluateAll(nodes => nodes.map(node => node.namespaceURI)))
          .toEqual(["http://www.w3.org/2000/svg", "http://www.w3.org/2000/svg"]);
      } else if (name === "07-binding-handler") {
        await root.locator("input").fill("needle");
        await expect(root.locator("input")).toHaveValue("needle");
        await expect(root.locator(".query")).toHaveText("needle");
        await expect(root.locator(".seen")).toHaveText("needle:a");
        await root.locator("select").selectOption("b");
        await expect(root.locator(".project")).toHaveText("b");
        await expect(root.locator(".seen")).toHaveText("needle:b");
      } else if (name === "08-event-dataset") {
        await root.locator("span").click();
        await expect(root.locator(".selected")).toHaveText(""); // target is span, intentionally empty
        await expect(root.locator(".target")).toHaveText("");
        await expect(root.locator(".part")).toHaveText("label");
        await expect(root.locator(".current")).toHaveText("log-001");
        await root.locator("tr").dispatchEvent("click");
        await expect(root.locator(".selected")).toHaveText("log-001");
        await expect(root.locator(".target")).toHaveText("log-001");
        await expect(root.locator(".part")).toHaveText("");
        await expect(root.locator(".current")).toHaveText("log-001");
      } else if (name === "09-wheel") {
        await root.locator("div").dispatchEvent("wheel", { deltaX: 4, deltaY: 12 });
        await expect(root.locator("output")).toHaveText("4:12:0:0");
      } else if (name === "12-assets-css") {
        await expect(root.locator(".shared")).toHaveCSS("color", "rgb(12, 34, 56)");
        await expect(root.locator("img")).toHaveJSProperty("naturalWidth", 1);
        await expect(root.locator("use")).toHaveAttribute("href", `${baseURL}/mochi-icons/home.svg#mochi-icon`);
        expect(fs.existsSync(path.join(bundle, "public/probe.svg"))).toBe(true);
        expect(fs.existsSync(path.join(bundle, "probe.svg"))).toBe(false);
        expect(fs.existsSync(path.join(bundle, "mochi-icons/home.svg"))).toBe(true);
        expect(fs.existsSync(path.join(bundle, "mochi-icons/unused.svg"))).toBe(false);
      }
      expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
      await settleConsole();
      expect(pageErrors).toEqual([]);
      expect(consoleErrors).toEqual([]);
      await testInfo.attach("browser-console", { body: JSON.stringify(consoleErrors), contentType: "application/json" });
    }, "<probe-root></probe-root>");
  });
}

for (const name of ["11-boolean", "11-boolean-contracts", "shared-form"]) {
  test(`Boolean declarations typecheck and build: ${name} @ui-form`, async ({}, testInfo) => {
    const source = name === "shared-form" ? fixture : path.join(fixture, "probes", name);
    await withCompiledProject(source, async (_baseURL, bundle) => {
      await attachArtifacts(testInfo, source, bundle);
      expect(fs.existsSync(path.join(bundle, "mochi-manifest.json"))).toBe(true);
    }, undefined, ["--typecheck"]);
  });
}

test("Ruby Boolean event contracts reject mismatches and recover @ui-form", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/11-boolean-contracts"), browserName);
  expect(output).toContain(`PASS [${browserName}] Boolean event payloads retain runtime validation`);
});


test("quoted form labels stay data across attributes, props, branches and events @ui-form", async ({ page }, testInfo) => {
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    const root = page.locator("nested-form-root");
    await expect(root.locator("field-editor .label").first()).toHaveText("Identity / Name");
    await root.locator(".adversarial").click();
    const label = `Label "' <img data-injected='yes'> & &quot; {end}`;
    await expect(root.locator(".quoted-static")).toHaveText(label);
    await expect(root.locator(".quoted-static")).toHaveAttribute("title", label);
    await expect(root.locator(".quoted-static")).toHaveAttribute("data-alt", label);
    await expect(root.locator(".quoted-static")).toHaveAttribute("data-interpolated", `${label}:}`);
    await expect(root.locator(".quoted-static")).toHaveAttribute("data-literal", "{literal}");
    await expect(root.locator(".quoted-branch")).toHaveAttribute("class", "quoted-branch active");
    await expect(root.locator(".quoted-branch")).toHaveAttribute("title", label);
    await expect(root.locator(".quoted-branch")).toHaveAttribute("data-entity", `" ${label} &`);
    await expect(root.locator('[data-field="a"] field-editor .label')).toHaveText(`Identity / ${label}`);
    await expect(root.locator('[data-field="a"]')).toHaveAttribute("title", label);
    await expect(root.locator('[data-field="a"]')).toHaveAttribute("data-literal", "{row}");
    await expect(root.locator('[data-field="a"]')).toHaveAttribute("data-entity", `" ${label} &`);
    await expect(root.locator('[data-field="a"] .pick')).toHaveAttribute("title", label);
    await root.locator(".quoted-event").click();
    await expect(root.locator(".last")).toHaveText(`${label}:}`);
    await root.locator(".quoted-escape").click();
    await expect(root.locator(".last")).toHaveText('quote: "x"');
    await root.locator('[data-field="a"] .quoted-row-event').click();
    await expect(root.locator(".last")).toHaveText(`Identity|${label}`);
    await root.locator(".toggle").click();
    await root.locator(".toggle").click();
    await expect(root.locator(".quoted-branch")).toHaveText(label);
    await expect(root.locator("field-editor")).toHaveCount(4);
    await expect(root.locator("img, script, [data-injected]")).toHaveCount(0);
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<nested-form-root></nested-form-root>");
});

test("nested form retains keyed editors and disposes conditional children @ui-form", async ({ page }, testInfo) => {
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    const root = page.locator("nested-form-root");
    const editor = () => root.locator('[data-field="a"] field-editor');
    await expect(root.locator("field-editor")).toHaveCount(4);
    await expect(editor().locator(".draft")).toHaveValue("Alpha");
    const originalInstance = await editor().evaluate((node: any) => {
      (window as any).__fieldA = node;
      return node._mochiInstance;
    });
    await editor().locator(".draft").fill("Retained draft");
    await expect(root.locator(".events")).toHaveText("1");
    await root.locator(".reorder").click();
    await root.locator(".reorder-fields").click();
    await root.locator(".insert").click();
    await expect(editor().locator(".draft")).toHaveValue("Retained draft");
    expect(await editor().evaluate((node: any) => node === (window as any).__fieldA)).toBe(true);
    expect(await editor().evaluate((node: any) => node._mochiInstance)).toBe(originalInstance);
    await root.locator('[data-field="a"] .pick').click();
    await expect(root.locator(".last")).toHaveText("g1:a:1:2:picked");
    await root.locator(".remove").click();
    await editor().locator(".draft").fill("Current indices");
    await expect(root.locator(".last")).toHaveText("g1:a:1:1:Current indices");
    await expect(root.locator(".events")).toHaveText("3");
    const baseline = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    for (let cycle = 0; cycle < 3; cycle++) {
      await editor().evaluate((node: any) => { (window as any).__removedEditor = node; });
      await root.locator(".toggle-group").click();
      await expect(root.locator("field-editor")).toHaveCount(2);
      await expect.poll(() => page.evaluate(() => (window as any).__removedEditor._mochiMountState)).toBe("unmounted");
      const disposed = await page.evaluate(() => ({
        ...(window as any).MochiLoader.debugStats(),
        instance: (window as any).__removedEditor._mochiInstance,
        targets: Object.keys((window as any).__removedEditor.bindingTargets).length,
      }));
      expect(disposed.instance).toBeNull();
      expect(disposed.targets).toBe(0);
      expect(disposed.components).toBe(baseline.components - 2);
      expect(disposed.elements).toBe(baseline.elements - 2);
      expect(disposed.bindings).toBeLessThan(baseline.bindings);
      expect(disposed.routeSubscribers).toBe(baseline.routeSubscribers - 2);
      await root.locator(".fresh").click();
      await root.locator(".toggle-group").click();
      await expect(editor().locator(".draft")).toHaveValue("Fresh a");
      await expect(editor().locator(".mount-count")).toHaveText("1");
      expect(await editor().evaluate((node: any) => node === (window as any).__removedEditor)).toBe(false);
      expect(await editor().evaluate((node: any) => node._mochiInstance)).not.toBe(originalInstance);
      await root.locator('[data-field="a"] .pick').click();
      await expect(root.locator(".last")).toHaveText("g1:a:1:1:picked");
      await expect(root.locator(".events")).toHaveText(String(4 + cycle));
      const restored = await page.evaluate(() => (window as any).MochiLoader.debugStats());
      for (const key of ["components", "elements", "bindings", "routeSubscribers", "timers", "pendingHostRequests", "unmountedInstances"]) {
        expect(restored[key], `${key} after cycle ${cycle}`).toBe(baseline[key]);
      }
    }
    await root.locator(".toggle").click();
    await expect(root.locator("field-editor")).toHaveCount(0);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().components)).toBe(1);
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<nested-form-root></nested-form-root>");
});

for (const open of [0, 1]) {
  test(`structural fragments retain table/select/HTML/SVG context, initially ${open} @ui-form`, async ({ page }, testInfo) => {
    const source = path.join(fixture, "probes/01-structural-contexts");
    const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
    await withCompiledProject(source, async (baseURL, bundle) => {
      await attachArtifacts(testInfo, source, bundle);
      await page.goto(baseURL);
      const root = page.locator("probe-root");
      const assertOpen = async () => {
        await expect(root.locator("tbody tr")).toHaveCount(2);
        await expect(root.locator("tbody tr").first()).toHaveText("Alpha");
        await expect(root.locator("tbody tr").last()).toHaveText("Disabled Beta");
        await expect(root.locator("select option")).toHaveCount(2);
        await expect(root.locator("select option").last()).toBeDisabled();
        await expect(root.locator("svg g circle")).toHaveAttribute("r", "4");
        await expect(root.locator("svg g rect")).toHaveAttribute("width", "8");
        expect(await root.locator("svg g circle").evaluate(node => node.namespaceURI)).toBe("http://www.w3.org/2000/svg");
        expect(await root.locator("foreignObject p").first().evaluate(node => node.namespaceURI)).toBe("http://www.w3.org/1999/xhtml");
        await expect(root.locator("foreignObject p")).toHaveText(["Alpha", "Beta"]);
      };
      const assertClosed = async () => {
        await expect(root.locator("tbody tr")).toHaveCount(1);
        await expect(root.locator("tbody td")).toHaveText("Closed");
        await expect(root.locator("select option")).toHaveText("Closed");
        await expect(root.locator("svg g text")).toHaveText("Closed");
        await expect(root.locator("foreignObject p")).toHaveText("Closed");
      };
      await expect(root.locator('.scope[data-id="a"] i')).toHaveText(["x:0", "y:1"]);
      await expect(root.locator('.scope[data-id="a"] output')).toHaveText("Alpha:0");
      await expect(root.locator('.scope[data-id="b"] output')).toHaveText("Beta:1");
      await (open ? assertOpen() : assertClosed());
      await root.locator(".toggle").click();
      await (open ? assertClosed() : assertOpen());
      await root.locator(".toggle").click();
      await (open ? assertOpen() : assertClosed());
      expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
      await settleConsole();
      expect(consoleErrors).toEqual([]);
      expect(pageErrors).toEqual([]);
    }, `<probe-root open="${open}"></probe-root>`);
  });
}

test("bound setter capacity failure blocks callback and permits later valid events @ui-form", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  const source = path.join(fixture, "probes/07-binding-failure");
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(source, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, source, bundle);
    await page.goto(baseURL);
    const root = page.locator("probe-root");
    await expect(root.locator(".query")).toHaveText("old");
    // Fits the event bridge and scratch arena; fails while persisting @query.
    await root.locator("input").fill("x".repeat(310000));
    const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
    expect(errors).toHaveLength(1);
    expect(errors[0].message).toContain("state bytes exhausted");
    expect(errors[0].phase).toBe("event");
    expect(errors[0].method).toMatch(/^__mochi_action_/);
    await expect(root.locator(".query")).toHaveText("old");
    await expect(root.locator(".calls")).toHaveText("0");
    expect(await page.evaluate(() => localStorage.getItem("bound-handler"))).toBeNull();
    await settleConsole();
    for (const error of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
      expect(error).toContain("state bytes exhausted");
    }
    await root.locator("input").fill("recovered");
    await expect(root.locator(".query")).toHaveText("recovered");
    await expect(root.locator(".calls")).toHaveText("1");
    expect(await page.evaluate(() => localStorage.getItem("bound-handler"))).toBe("recovered");
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<probe-root></probe-root>", ["--capacity-config", path.join(source, "capacity.json")]);
});

for (const initiallyOpen of [true, false]) {
  test(`graph SVG insertion and keyed updates (initial open=${initiallyOpen}) @ui-graph`, async ({ page }, testInfo) => {
    const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
    await page.addInitScript(() => {
      const audit = (window as any).__svgAudit = { invalid: [], inserted: [], writes: [] };
      const svgNamespace = "http://www.w3.org/2000/svg";
      const geometry = ["d", "transform", "r", "stroke-width"];
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this.namespaceURI === svgNamespace && geometry.includes(name)) {
          if (/[{}\uE000-\uE00F]/.test(value)) audit.invalid.push(`${name}=${value}`);
          if (name === "d" && this.matches(".edge")) audit.writes.push(this.getAttribute("data-edge"));
        }
        return setAttribute.call(this, name, value);
      };
      const inspect = (node: Node) => {
        const nodes = [...(node instanceof Element ? [node] : []), ...((node as ParentNode).querySelectorAll?.("*") || [])];
        for (const element of nodes) {
          if (element.matches(".edge")) {
            const d = element.getAttribute("d") || "";
            audit.inserted.push(element.getAttribute("data-edge"));
            if (element.namespaceURI !== svgNamespace || !/^M \d+ \d+ L \d+ \d+$/.test(d)) {
              audit.invalid.push(`insert ${element.tagName}: ${d}`);
            }
          }
          if (element.namespaceURI === svgNamespace) {
            for (const name of geometry) {
              if (/[{}\uE000-\uE00F]/.test(element.getAttribute(name) || "")) audit.invalid.push(`insert ${name}`);
            }
            if (element.matches(".scene, .node") && !/^translate\(\d+ \d+\)$/.test(element.getAttribute("transform") || "")) {
              audit.invalid.push("insert incomplete transform");
            }
            if (element.matches(".node circle") && !/^\d+$/.test(element.getAttribute("r") || "")) audit.invalid.push("insert incomplete radius");
          }
        }
      };
      // Inspect synchronously before insertion: MutationObserver sees only the
      // final state and cannot detect transient invalid geometry.
      const insertBefore = Node.prototype.insertBefore;
      Node.prototype.insertBefore = function <T extends Node>(node: T, before: Node | null): T {
        if (this.isConnected) inspect(node);
        return insertBefore.call(this, node, before) as T;
      };
      const appendChild = Node.prototype.appendChild;
      Node.prototype.appendChild = function <T extends Node>(node: T): T {
        if (this.isConnected) inspect(node);
        return appendChild.call(this, node) as T;
      };
    });
    await withCompiledProject(fixture, async (baseURL, bundle) => {
      await attachArtifacts(testInfo, fixture, bundle);
      await page.goto(baseURL);
      const root = page.locator("editable-graph-root");
      if (!initiallyOpen) {
        await expect(root.locator(".closed")).toHaveText("Graph closed");
        await root.locator(".toggle").click();
      }
      await expect(root.locator(".edge")).toHaveCount(3);
      await expect(root.locator(".node")).toHaveCount(4);
      const validate = async () => {
        expect(await root.evaluate(host => {
          const svg = host.shadowRoot!.querySelector("svg")!;
          return {
            namespaces: [...svg.querySelectorAll("*")].every(node => node.namespaceURI === "http://www.w3.org/2000/svg"),
            marker: !!svg.querySelector("defs marker#arrowhead path"),
            viewBox: svg.getAttribute("viewBox"),
            refX: svg.querySelector("marker")!.getAttribute("refX"),
            references: [...svg.querySelectorAll(".edge")].map(node => node.getAttribute("marker-end")),
            invalid: (window as any).__svgAudit.invalid,
          };
        })).toEqual({ namespaces: true, marker: true, viewBox: "0 0 400 220", refX: "8", references: Array(3).fill("url(#arrowhead)"), invalid: [] });
      };
      await validate();
      await root.evaluate(host => {
        (window as any).__graphNodes = Object.fromEntries([...host.shadowRoot!.querySelectorAll("[data-edge], [data-node]")]
          .map(node => [node.getAttribute("data-edge") || node.getAttribute("data-node"), node]));
        (window as any).__svgAudit.writes = [];
      });
      const sameNodes = () => root.evaluate(host => [...host.shadowRoot!.querySelectorAll("[data-edge], [data-node]")]
        .every(node => (window as any).__graphNodes[node.getAttribute("data-edge") || node.getAttribute("data-node")!] === node));
      const takeWrites = () => page.evaluate(() => (window as any).__svgAudit.writes.splice(0).sort());
      await root.locator(".move").click();
      await expect(root.locator('[data-edge="ab"]')).toHaveAttribute("d", "M 40 50 L 200 60");
      await expect(root.locator('[data-edge="bc"]')).toHaveAttribute("d", "M 200 60 L 180 150");
      await expect(root.locator('[data-edge="cd"]')).toHaveAttribute("d", "M 180 150 L 320 150");
      expect(await takeWrites()).toEqual(["ab", "bc"]);
      expect(await sameNodes()).toBe(true);
      await root.locator(".reorder").click();
      await expect(root.locator(".edge").first()).toHaveAttribute("data-edge", "cd");
      expect(await sameNodes()).toBe(true);
      expect(await takeWrites()).toEqual([]);
      await root.locator(".remove").click();
      await expect(root.locator(".edge")).toHaveCount(2);
      expect(await sameNodes()).toBe(true);
      await root.locator(".restore").click();
      await expect(root.locator(".edge")).toHaveCount(3);
      await expect(root.locator('[data-edge="bc"]')).toHaveAttribute("d", "M 200 60 L 180 150");
      expect(await root.locator('[data-edge="bc"]').evaluate(node => node !== (window as any).__graphNodes.bc)).toBe(true);
      for (const id of ["ab", "cd"]) {
        expect(await root.locator(`[data-edge="${id}"]`).evaluate((node, key) => node === (window as any).__graphNodes[key], id)).toBe(true);
      }
      expect(await takeWrites()).toEqual(["bc"]);
      await root.locator(".pan").click();
      await expect(root.locator(".scene")).toHaveAttribute("transform", "translate(10 5)");
      expect(await takeWrites()).toEqual([]);
      for (let cycle = 0; cycle < 3; cycle++) {
        await root.locator(".toggle").click();
        await expect(root.locator("svg")).toHaveCount(0);
        await root.locator(".toggle").click();
        await expect(root.locator('[data-edge="bc"]')).toHaveAttribute("d", "M 200 60 L 180 150");
        await validate();
      }
      expect(await page.evaluate(() => (window as any).__svgAudit.inserted.length)).toBeGreaterThanOrEqual(13);
      await root.evaluate(async (host: any) => {
        const replacement: any = document.createElement("editable-graph-root");
        replacement.setAttribute("open", host.getAttribute("open"));
        host.replaceWith(replacement);
        await replacement._mochiReady;
      });
      if (!initiallyOpen) await root.locator(".toggle").click();
      await expect(root.locator('[data-edge="ab"]')).toHaveAttribute("d", "M 40 50 L 180 50");
      await validate();
      expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
      await settleConsole();
      expect(consoleErrors).toEqual([]);
      expect(pageErrors).toEqual([]);
    }, `<editable-graph-root open="${initiallyOpen}"></editable-graph-root>`);
  });
}

test("Ruby event identity and envelope recovery scenarios @ui-inspector @ui-graph", async ({ browserName }) => {
  const output = runRubyProject(path.join(fixture, "probes/08-event-dataset"), browserName);
  expect(output).toContain(`PASS [${browserName}] descendant clicks keep target data separate`);
});

test("target and handler dataset overflow reports source and permits later clicks @ui-inspector @ui-graph", async ({ page }, testInfo) => {
  const source = path.join(fixture, "probes/08-event-dataset");
  const lines = fs.readFileSync(path.join(source, "lib/ProbeRoot.rb"), "utf8").split("\n");
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(source, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, source, bundle);
    await page.goto(baseURL);
    const root = page.locator("probe-root");
    let calls = 0;
    for (const selector of [".oversize-target", ".oversize-handler"]) {
      await root.locator(selector).click();
      await root.locator("span").click();
      await expect(root.locator(".calls")).toHaveText(String(calls));
      const errors = await page.evaluate(() => (window as any).__uiErrors.splice(0));
      expect(errors).toHaveLength(1);
      expect(errors[0].method).toBe("select_row");
      expect(errors[0].message).toMatch(/ABI event argument bytes exhausted \(requested \d+, used 0 of 8192\)/);
      expect(errors[0].source).toBe(`lib/ProbeRoot.rb:${lines.indexOf("  def select_row(event)") + 1}`);
      expect(errors[0].capacityProfile).toMatch(/^[a-f0-9]{64}$/);
      await settleConsole();
      for (const message of [...consoleErrors.splice(0), ...pageErrors.splice(0)]) {
        expect(message).toContain("ABI event argument bytes exhausted");
      }
      await root.locator(".reset").click();
      await root.locator("span").click();
      await expect(root.locator(".calls")).toHaveText(String(++calls));
      await expect(root.locator(".current")).toHaveText("log-001");
      await expect(root.locator(".selected")).toHaveText("");
    }
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<probe-root></probe-root>");
});

test("graph and inspector select bound identities from surfaces and descendants @ui-inspector @ui-graph", async ({ page }, testInfo) => {
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    const graph = page.locator("editable-graph-root");
    const inspector = page.locator("inspector-root");
    await expect(graph.locator(".node")).toHaveCount(4);
    await expect(inspector.locator("tr.record")).toHaveCount(12);
    for (const [root, selector, id, other] of [
      [graph, '[data-node="b"]', "b", '[data-node="c"] circle'],
      [inspector, '[data-id="record-3"]', "record-3", '[data-id="record-4"] button'],
    ] as const) {
      // Direct bound-node event distinguishes surface data from a descendant's
      // data. Native descendant clicks then exercise actual browser hit testing.
      await root.locator(selector).dispatchEvent("click");
      await expect(root.locator(".selected-id")).toHaveText(id);
      await root.locator(other).click();
      const label = root.locator(`${selector} ${id === "b" ? "text" : ".message"}`);
      await label.scrollIntoViewIfNeeded();
      // WebKit's driver bounding box omits SVG text x/baseline offsets. Use
      // the browser's client rect and verify the hit before native mouse input.
      const point = await label.evaluate(node => {
        const rect = node.getBoundingClientRect();
        const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
        if ((node.getRootNode() as ShadowRoot).elementFromPoint(x, y) !== node) {
          throw new Error("label is not the native click target");
        }
        return { x, y };
      });
      await page.mouse.click(point.x, point.y);
      await expect(root.locator(".selected-id")).toHaveText(id);
      expect(await root.locator(selector).getAttribute("id")).toBeNull();
    }
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<editable-graph-root></editable-graph-root><inspector-root></inspector-root>");
});

test("graph history restores complete rendered snapshots across the forty-entry boundary @ui-graph", async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    const root = page.locator("editable-graph-root");
    await expect(root.locator(".node")).toHaveCount(4);
    const readGraph = () => root.evaluate(host => {
      const shadow = host.shadowRoot!;
      return {
        nodes: [...shadow.querySelectorAll(".node")].map(node => ({
          id: node.getAttribute("data-node"), transform: node.getAttribute("transform"),
          label: node.querySelector("text")!.textContent, radius: node.querySelector("circle")!.getAttribute("r"),
          namespace: node.namespaceURI,
        })),
        edges: [...shadow.querySelectorAll(".edge")].map(node => ({
          id: node.getAttribute("data-edge"), path: node.getAttribute("d"), marker: node.getAttribute("marker-end"),
          namespace: node.namespaceURI,
        })),
        selected: shadow.querySelector(".selected-id")!.textContent,
      };
    });
    const states = [await readGraph()];
    for (let edit = 1; edit <= 45; edit++) {
      await root.locator(".move").click();
      states.push(await readGraph());
      await expect(root.locator(".undo-count")).toHaveText(String(Math.min(edit, 40)));
    }
    for (let step = 1; step <= 40; step++) {
      await root.locator(".undo").click();
      expect(await readGraph()).toEqual(states[45 - step]);
      await expect(root.locator(".redo-count")).toHaveText(String(step));
      await expect(root.locator(".undo-count")).toHaveText(String(40 - step));
    }
    await root.locator(".undo").click();
    expect(await readGraph()).toEqual(states[5]);
    for (let step = 1; step <= 40; step++) {
      await root.locator(".redo").click();
      expect(await readGraph()).toEqual(states[5 + step]);
      await expect(root.locator(".undo-count")).toHaveText(String(step));
      await expect(root.locator(".redo-count")).toHaveText(String(40 - step));
    }
    await root.locator(".undo").click();
    await root.locator(".add-node").click();
    await expect(root.locator(".redo-count")).toHaveText("0");
    const branched = await readGraph();
    await root.locator(".redo").click();
    expect(await readGraph()).toEqual(branched);
    await root.locator(".undo").click();
    expect(await readGraph()).toEqual(states[44]);
    await root.locator(".redo").click();
    expect(await readGraph()).toEqual(branched);
    const mixed = [branched];
    for (const action of [".reorder", ".remove", ".restore", ".remove-node", ".add-node"]) {
      await root.locator(action).click();
      mixed.push(await readGraph());
    }
    for (let index = mixed.length - 2; index >= 0; index--) {
      await root.locator(".undo").click();
      expect(await readGraph()).toEqual(mixed[index]);
    }
    for (let index = 1; index < mixed.length; index++) {
      await root.locator(".redo").click();
      expect(await readGraph()).toEqual(mixed[index]);
    }
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, "<editable-graph-root></editable-graph-root>");
});

test("graph pointer ownership is lazy and releases on cancellation branch removal and disposal @ui-graph", async ({ page }, testInfo) => {
  test.setTimeout(90_000);
  const requests: string[] = [];
  page.on("request", request => requests.push(new URL(request.url()).pathname));
  const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
  await page.setViewportSize({ width: 1280, height: 1100 });
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    await expect(page.locator("inspector-root .record")).toHaveCount(12);
    expect(requests.filter(url => url.endsWith("/mochi-pointer.js"))).toEqual([]);
    expect(requests.some(url => /\/components\/editable-graph-root\.(json|chi)$/.test(url))).toBe(false);
    const pointerFiles: string[] = await page.evaluate(() => {
      const manifest = (window as any).MochiLoader.manifest;
      return manifest.capabilities.pointer.packages.map((id: string) => manifest.packages[id].file);
    });
    for (const file of pointerFiles) expect(requests.some(url => url.endsWith("/" + file))).toBe(false);
    const baseline = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    await page.evaluate(() => {
      // The registrar itself is lazy when the inspector uses no capabilities.
      let registrar: any;
      Object.defineProperty(window, "MochiHostAdapter", {
        configurable: true,
        get: () => registrar,
        set(value) {
          const register = value.register;
          value.register = function (adapter: any) {
            if (adapter.name === "pointer") (window as any).__graphPointer = adapter;
            return register.call(this, adapter);
          };
          registrar = value;
        },
      });
      document.addEventListener("pointerdown", event => { (window as any).__graphPointerId = event.pointerId; }, true);
    });
    const count = () => page.evaluate(() => (window as any).__graphPointer.debugCaptureCount());
    for (let mount = 0; mount < 3; mount++) {
      await page.evaluate(async () => {
        const host: any = document.createElement("editable-graph-root");
        host.style.display = "block";
        document.body.appendChild(host);
        await host._mochiReady;
      });
      const root = page.locator("editable-graph-root");
      for (const terminal of ["cancel", "lost_capture", "closed"]) {
        const circle = root.locator('[data-node="b"] circle');
        await circle.scrollIntoViewIfNeeded();
        const point = await circle.evaluate(node => {
          const rect = node.getBoundingClientRect();
          return { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
        });
        await page.mouse.move(point.x, point.y);
        await page.mouse.down();
        await expect(root.locator(".drag-state")).toHaveText("dragging");
        expect(await count()).toBe(1);
        expect(await root.locator('[data-node="b"]').evaluate(node => node.hasPointerCapture((window as any).__graphPointerId))).toBe(true);
        await page.mouse.move(point.x + 40, point.y + 20);
        await expect(root.locator('[data-node="b"]')).toHaveAttribute("transform", "translate(220 70)");
        if (terminal === "closed") {
          await root.locator(".toggle").dispatchEvent("click");
        } else {
          await root.locator('[data-node="b"]').evaluate((node, terminal) => {
            const pointerId = (window as any).__graphPointerId;
            if (terminal === "cancel") node.dispatchEvent(new PointerEvent("pointercancel", { bubbles: true, composed: true, pointerId }));
            else node.releasePointerCapture(pointerId);
          }, terminal);
          // Native loss of capture is delivered on the next pointer input.
          if (terminal === "lost_capture") await page.mouse.move(point.x + 41, point.y + 20);
        }
        await expect(root.locator(".drag-state")).toHaveText("idle");
        await expect(root.locator(".terminal")).toHaveText(terminal);
        await expect(root.locator(".undo-count")).toHaveText("0");
        await page.mouse.up();
        expect(await count()).toBe(0);
        if (terminal === "closed") await root.locator(".toggle").click();
        await expect(root.locator('[data-node="b"]')).toHaveAttribute("transform", "translate(180 50)");
      }
      const circle = root.locator('[data-node="b"] circle');
      await circle.scrollIntoViewIfNeeded();
      const point = await circle.evaluate(node => {
        const rect = node.getBoundingClientRect();
        return { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
      });
      await page.mouse.move(point.x, point.y);
      await page.mouse.down();
      await expect(root.locator(".drag-state")).toHaveText("dragging");
      expect(await count()).toBe(1);
      await root.evaluate(host => host.remove());
      await expect.poll(count).toBe(0);
      await page.mouse.up();
      const stats = await page.evaluate(() => (window as any).MochiLoader.debugStats());
      expect(stats.pendingPointerMoves).toBe(0);
      expect(stats.components).toBe(baseline.components);
      expect(stats.bindings).toBe(baseline.bindings);
    }
    expect(requests.filter(url => url.endsWith("/mochi-pointer.js"))).toHaveLength(1);
    for (const file of pointerFiles) expect(requests.filter(url => url.endsWith("/" + file))).toHaveLength(1);
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    await settleConsole();
    expect(consoleErrors).toEqual([]);
    expect(pageErrors).toEqual([]);
  }, '<inspector-root style="display:block"></inspector-root>');
});
