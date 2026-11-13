import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withFrameworkProject } from "./framework_helpers";

const repoRoot = path.resolve(__dirname, "..", "..");
const compiler = path.join(repoRoot, "compiler", "mochi");
const fixture = path.join(__dirname, "..", "fixtures", "framework_contracts");

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
    expect(manifest.capabilities.drag.packages).toContain("ruby:lib/mochi_builtin_drag.rb");
    expect(manifest.capabilities.files.packages).toContain("ruby:lib/mochi_builtin_files.rb");

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

test("file inputs and controlled file drops stream bounded bytes from mount-owned handles", async ({ page }) => {
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
      operations: {
        release: "sync", open: "sync", close: "sync", read_next: "async",
        read: "async", read_text: "async",
      },
      limits: {
        handles: 128, metadata_bytes: 8192, readers: 4,
        chunk_bytes: 8192, whole_read_bytes: 48000, envelope_bytes: 65536,
      },
    });
    expect(manifest.capabilities.drag.packages).toContain("ruby:lib/mochi_builtin_drag.rb");

    await expect(page.locator("file-contract .input-files")).toHaveText("");
    const input = page.locator("file-contract .file-input");
    const streamBytes = Buffer.from(Array.from({ length: 65537 }, (_, index) => index % 256));
    let checksum = 0;
    for (const byte of streamBytes) checksum = (checksum * 31 + byte) % 2147483647;
    await input.setInputFiles([
      { name: "empty.bin", mimeType: "", buffer: Buffer.from("") },
      { name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hello") },
      { name: "large.bin", mimeType: "application/octet-stream", buffer: streamBytes },
    ]);
    const inputText = await page.locator("file-contract .input-files").textContent();
    expect(inputText).toMatch(/empty\.bin:0:(?:application\/octet-stream)?:/);
    expect(inputText).toContain("notes.txt:5:text/plain:");
    expect(inputText).toContain("large.bin:65537:application/octet-stream:");
    await expect(page.locator("file-contract .stream-result")).toHaveText(`eof:65537:${checksum}`);
    const inputHandles = [...(inputText || "").matchAll(/mochi-file-\d+/g)].map((match) => match[0]);
    expect(new Set(inputHandles).size).toBe(3);

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

test("Ruby-authored file, drop, and structured drag tests run through mochi test", async ({ browserName }) => {
  test.setTimeout(240_000);
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-file-tests-"));
  try {
    fs.cpSync(fixture, project, { recursive: true });
    fs.writeFileSync(path.join(project, "index.html"),
      "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>");
    const output = execFileSync(compiler,
      ["test", "-i", project, `--browsers=${browserName}`],
      { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
    expect(output).toContain("file input reads exact binary bytes and strict UTF-8 text");
    expect(output).toContain("file drops stream oversized files and report errors and cancellation");
    expect(output).toContain("structured drag actions deliver Ruby values and state");
  } catch (error: any) {
    throw new Error([error.stderr, error.stdout, error.message].filter(Boolean).join("\n"));
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
