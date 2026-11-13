import { test, expect } from "@playwright/test";
import { withFrameworkProject } from "./framework_helpers";

test("Ruby transfers typed values and external text during native drag event windows", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__dragErrors = [];
    document.addEventListener("mochi:error", (event) => {
      (window as any).__dragErrors.push((event as CustomEvent).detail);
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const manifest = await page.evaluate(async () => await (await fetch("mochi-manifest.json")).json());
    expect(manifest.capabilities.drag).toMatchObject({
      version: 1,
      host: "mochi-drag.js",
      operations: { set_data: "sync", set_text: "sync", accept: "sync" },
      limits: { payload_bytes: 1024 },
    });
    expect(Object.keys(manifest.packages)).toContain("capability:drag");
    expect(manifest.capabilities.files).toBeUndefined();

    const root = page.locator("drag-target");
    const source = page.locator("drag-source");
    await expect(root.locator(".typed")).toHaveText("none");
    await source.locator(".typed-source").dragTo(root.locator(".drop-zone"));
    await expect(root.locator(".typed")).toHaveText("false::9223372036854775807:ruby,mochi");
    await expect(root.locator(".effect")).toHaveText("move");
    await expect(root.locator(".source")).toHaveText("button");

    await source.locator(".text-source").dragTo(root.locator(".text-zone"));
    await expect(root.locator(".text-result")).toHaveText("external text stays text");

    await root.locator(".text-zone").evaluate((target) => {
      const transfer = new DataTransfer();
      transfer.setData("text/plain", "external text stays text");
      const over = new DragEvent("dragover", { bubbles: true, cancelable: true, composed: true, dataTransfer: transfer });
      target.dispatchEvent(over);
      if (!over.defaultPrevented) throw new Error("accepted text dragover was not prevented");
      target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, composed: true, dataTransfer: transfer }));
    });
    await expect(root.locator(".text-result")).toHaveText("external text stays text");
    expect(await page.evaluate(() => (window as any).__dragErrors)).toEqual([]);
  }, "<drag-source></drag-source><drag-target></drag-target>");

  expect(errors).toEqual([]);
});

test("file inputs and controlled file drops expose bounded metadata-only mount handles", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__fileErrors = [];
    document.addEventListener("mochi:error", (event) => {
      (window as any).__fileErrors.push((event as CustomEvent).detail);
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const manifest = await page.evaluate(async () => await (await fetch("mochi-manifest.json")).json());
    expect(manifest.capabilities.files).toMatchObject({
      version: 1,
      host: "mochi-files.js",
      operations: { release: "sync" },
      limits: { handles: 128, metadata_bytes: 8192 },
    });
    expect(manifest.capabilities.drag).toBeUndefined();

    const input = page.locator("file-contract .file-input");
    await input.setInputFiles([
      { name: "empty.bin", mimeType: "", buffer: Buffer.from("") },
      { name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hello") },
    ]);
    const inputText = await page.locator("file-contract .input-files").textContent();
    expect(inputText).toContain("empty.bin:0::");
    expect(inputText).toContain("notes.txt:5:text/plain:");
    const inputHandles = [...(inputText || "").matchAll(/mochi-file-\d+/g)].map((match) => match[0]);
    expect(new Set(inputHandles).size).toBe(2);

    await page.locator("file-contract .file-drop").evaluate((target) => {
      const transfer = new DataTransfer();
      transfer.items.add(new File(["drop-data"], "dropped.txt", { type: "text/plain", lastModified: 2345 }));
      const over = new DragEvent("dragover", { bubbles: true, cancelable: true, composed: true, dataTransfer: transfer });
      target.dispatchEvent(over);
      if (!over.defaultPrevented) throw new Error("file dragover was not accepted");
      target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, composed: true, dataTransfer: transfer }));
    });
    const dropText = await page.locator("file-contract .drop-files").textContent();
    expect(dropText).toContain("dropped.txt:9:text/plain:2345:");
    expect([...((dropText || "").matchAll(/mochi-file-\d+/g))].map((match) => match[0])[0]).not.toBe(inputHandles[0]);
    expect(await page.evaluate(() => (window as any).__fileErrors)).toEqual([]);
  }, "<file-contract></file-contract>");

  expect(errors).toEqual([]);
});
