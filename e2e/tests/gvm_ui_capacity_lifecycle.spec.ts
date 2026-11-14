import { test, expect } from "@playwright/test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withCompiledProject } from "./framework_helpers";

// The real working set fits; retained garbage, bindings, or subscriptions do
// not get a larger default pool in which to hide. This is a correctness test.
const capacities = {
  scratch_objects: 1024, scratch_bytes: 65536, scratch_slots: 2048,
  state_objects: 24576, state_slots: 65536, state_ivars: 8192,
  state_bytes: 1048576, bindings: 256, state_components: 16,
};

test("three fixtures reuse a bounded profile through 100 interaction and 100 mount cycles @ui-inspector @ui-graph @ui-form", async ({ page }) => {
  test.setTimeout(240_000);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-ui-lifecycle-"));
  const profile = path.join(directory, "capacity.json");
  fs.writeFileSync(profile, JSON.stringify({ schema_version: 1, capacities }));
  const failures: string[] = [];
  page.on("pageerror", error => failures.push(error.message));
  await page.addInitScript(() => {
    (window as any).__capacityErrors = [];
    document.addEventListener("mochi:error", event => (window as any).__capacityErrors.push((event as CustomEvent).detail.message));
  });
  try {
    await withCompiledProject(path.join(__dirname, "../fixtures/ui_contracts"), async url => {
      await page.goto(url);
      const inspector = page.locator("inspector-root");
      const graph = page.locator("editable-graph-root");
      const form = page.locator("nested-form-root");
      const stats = () => page.evaluate(() => (window as any).MochiLoader.debugStats());
      const mountAll = async () => {
        await page.evaluate(async () => {
          for (const tag of ["inspector-root", "editable-graph-root", "nested-form-root"]) {
            await customElements.whenDefined(tag);
            const element = document.createElement(tag) as any;
            document.body.appendChild(element);
            await element._mochiReady;
          }
        });
        await expect(inspector.locator(".record")).toHaveCount(12);
        await expect(graph.locator(".edge")).toHaveCount(3);
        await expect(form.locator("field-editor .draft")).toHaveCount(4);
        await expect.poll(async () => (await stats()).routeSubscribers).toBe(4);
      };
      await mountAll();
      const live = await stats();
      expect(live.capacityProfile.capacities).toMatchObject(capacities);
      for (let cycle = 0; cycle < 100; cycle++) {
        await inspector.locator(".next").click();
        await expect(inspector.locator(".page")).toHaveText("2");
        await inspector.locator(".filter").fill("Record 48");
        await expect(inspector.locator(".page")).toHaveText("1");
        await inspector.locator(".filter").fill("");
        await inspector.locator(".append").click();
        await expect(inspector.locator(".total")).toHaveText("480");
        await expect(inspector.locator(".record").first()).toHaveAttribute("data-id", `record-${cycle + 2}`);
        await expect(inspector.locator(".record")).toHaveCount(12);

        const original = await graph.locator(".edge").first().getAttribute("d");
        await graph.locator(".move").click();
        await expect(graph.locator(".edge").first()).not.toHaveAttribute("d", original!);
        await graph.locator(".undo").click();
        await expect(graph.locator(".edge").first()).toHaveAttribute("d", original!);
        await graph.locator(".redo").click();
        await expect(graph.locator(".undo-count")).toHaveText(String(Math.min(cycle + 1, 40)));
        await expect(graph.locator(".redo-count")).toHaveText("0");

        await form.locator("[data-field='a'] field-editor .draft").fill(`draft-${cycle}`);
        await expect(form.locator(".events")).toHaveText(String(cycle + 1));
        await form.locator(".toggle").click();
        await expect(form.locator("field-editor")).toHaveCount(0);
        await expect.poll(async () => (await stats()).routeSubscribers).toBe(0);
        await form.locator(".toggle").click();
        await expect(form.locator("[data-field='a'] field-editor .draft")).toHaveValue("Alpha");
        await expect.poll(async () => (await stats()).routeSubscribers).toBe(4);
        const current = await stats();
        expect(current.components).toBe(live.components);
        expect(current.bindings).toBe(live.bindings);
        expect(current.pendingHostRequests).toBe(0);
      }
      const removeAll = async () => {
        await page.evaluate(() => document.querySelectorAll("inspector-root, editable-graph-root, nested-form-root").forEach(el => el.remove()));
        await expect.poll(async () => (await stats()).components).toBe(0);
      };
      await removeAll();
      const released = await stats();
      expect(released.bindings).toBe(0);
      expect(released.routeSubscribers).toBe(0);
      for (let cycle = 0; cycle < 100; cycle++) {
        await mountAll();
        await inspector.locator("[data-id='record-3'] .message").click();
        await expect(inspector.locator(".selected-detail")).toHaveText("worker-3:3");
        await graph.locator(".move").click();
        await expect(graph.locator(".undo-count")).toHaveText("1");
        await removeAll();
        const current = await stats();
        for (const key of ["bindings", "routeSubscribers", "pendingHostRequests", "pendingPointerMoves", "timers"]) expect(current[key]).toBe(0);
        expect(current.stateAllocated).toBe(released.stateAllocated);
        expect(current.stateFreeBytes).toBe(released.stateFreeBytes);
      }
      expect(await page.evaluate(() => (window as any).__capacityErrors)).toEqual([]);
      expect(failures).toEqual([]);
    }, "", ["--capacity-config", profile]);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
