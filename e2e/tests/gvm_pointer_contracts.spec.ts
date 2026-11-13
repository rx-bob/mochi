import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withFrameworkProject } from "./framework_helpers";

const repoRoot = path.resolve(__dirname, "..", "..");
const compiler = path.join(repoRoot, "compiler", "mochi");
const fixture = path.join(__dirname, "..", "fixtures", "framework_contracts");

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
    expect(manifest.capabilities.pointer.packages).toContain("ruby:lib/mochi_builtin_pointer.rb");
    await expect(root.locator(".position")).toHaveText("0,0");

    const handle = root.locator(".handle");
    const box = await handle.boundingBox();
    if (!box) throw new Error("pointer handle has no layout box");
    const startX = box.x + box.width / 2;
    const startY = box.y + box.height / 2;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(startX + 240, startY + 130, { steps: 4 });
    await expect.poll(async () => {
      const [x, y] = (await root.locator(".position").textContent() || "").split(",").map(Number);
      return Math.abs(x - (startX + 240)) < 3 && Math.abs(y - (startY + 130)) < 3;
    }).toBe(true);
    await expect(root.locator(".identity")).toContainText("mouse:");
    await page.mouse.up();
    expect(await page.evaluate(() => (window as any).__pointerErrors)).toEqual([]);
  }, "<pointer-contracts-root></pointer-contracts-root>");

  expect(errors).toEqual([]);
});

test("Ruby-authored pointer lifecycle tests run through mochi test", async ({ browserName }) => {
  test.setTimeout(240_000);
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi pointer tests "));
  try {
    fs.cpSync(fixture, project, { recursive: true });
    fs.writeFileSync(path.join(project, "index.html"),
      "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>");
    let output = "";
    try {
      output = execFileSync(compiler,
        ["test", "-i", project, `--browsers=${browserName}`],
        { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
    } catch (error: any) {
      throw new Error([error.stderr, error.stdout, error.message].filter(Boolean).join("\n"));
    }
    expect(output).toContain("pointer drag coalesces moves and releases at latest position");
    expect(output).toContain("cancel, lost capture, and unmount clear gesture ownership");
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
