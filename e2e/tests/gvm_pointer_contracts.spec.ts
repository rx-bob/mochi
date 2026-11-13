import { test, expect } from "@playwright/test";
import { withFrameworkProject } from "./framework_helpers";

test("Ruby pointer capture continues a drag outside its shadow root and releases explicitly", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__pointerErrors = [];
    document.addEventListener("mochi:error", (event) => {
      (window as any).__pointerErrors.push((event as CustomEvent).detail);
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("pointer-contracts-root");
    const manifest = await page.evaluate(async () => await (await fetch("mochi-manifest.json")).json());
    expect(manifest.capabilities.pointer).toMatchObject({
      version: 1,
      host: "mochi-pointer.js",
      operations: { capture: "sync", release: "sync" },
    });
    expect(Object.keys(manifest.packages)).toContain("capability:pointer");
    await expect(root.locator(".position")).toHaveText("0,0");

    const handle = root.locator(".handle");
    const box = await handle.boundingBox();
    if (!box) throw new Error("pointer handle has no layout box");
    const startX = box.x + box.width / 2;
    const startY = box.y + box.height / 2;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(startX + 240, startY + 130, { steps: 4 });
    await expect(root.locator(".position")).toHaveText(`${Math.round(startX + 240)},${Math.round(startY + 130)}`);
    await expect(root.locator(".identity")).toContainText("mouse:");
    await page.mouse.up();
    expect(await page.evaluate(() => (window as any).__pointerErrors)).toEqual([]);
  }, "<pointer-contracts-root></pointer-contracts-root>");

  expect(errors).toEqual([]);
});
