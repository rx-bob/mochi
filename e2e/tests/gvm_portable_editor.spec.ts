import { expect, test } from "@playwright/test";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";

const project = path.join(__dirname, "../fixtures/clay_editor");

test("portable editor runs the shared Ruby edit scenario", ({ browserName }) => {
  expect(runRubyProject(project, browserName, "editor_test.rb"))
    .toContain(`PASS [${browserName}] commits portable edits before Ruby handlers run`);
});

test("portable editor retains selection and commits IME text once", async ({ page, browserName }) => {
  await withCompiledProject(project, async url => {
    const requests: string[] = [];
    page.on("request", request => requests.push(request.url()));
    await page.goto(url);
    const name = page.getByRole("textbox", { name: "Station name" });
    const open = page.getByRole("checkbox", { name: "Open to public" });
    const history = page.locator("[data-view=history]");
    const refresh = page.getByRole("button", { name: "Refresh status" });

    await expect(name).toHaveValue("Harbor");
    await expect(open).toBeEnabled();
    await expect(open).not.toBeChecked();
    const original = await name.elementHandle();
    await name.focus();
    await name.evaluate((field: HTMLInputElement) => field.setSelectionRange(1, 4));
    await refresh.evaluate((button: HTMLButtonElement) => button.click());
    await expect(page.locator("[data-view=status]")).toHaveText("Refreshes: 1");
    expect(await name.evaluate((field: HTMLInputElement) => [field.selectionStart, field.selectionEnd])).toEqual([1, 4]);

    await name.evaluate((field: HTMLInputElement) => field.select());
    const cdp = browserName === "chromium" ? await page.context().newCDPSession(page) : null;
    if (cdp) {
      await cdp.send("Input.imeSetComposition", { text: "e", selectionStart: 1, selectionEnd: 1 });
    } else {
      // Playwright exposes the browser IME bridge only in Chromium.
      await name.evaluate((field: HTMLInputElement) => {
        field.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
        field.value = "e";
        field.setSelectionRange(1, 1);
        field.dispatchEvent(new InputEvent("input", { bubbles: true, isComposing: true, inputType: "insertCompositionText" }));
      });
    }
    await expect(name).toHaveValue("e");
    await expect(history).toHaveText("");
    await refresh.evaluate((button: HTMLButtonElement) => button.click());
    await expect(page.locator("[data-view=status]")).toHaveText("Refreshes: 2");
    await page.setViewportSize({ width: 335, height: 560 });
    await expect(name).toHaveValue("e");
    await expect(name).toBeFocused();
    expect(await name.evaluate((field: HTMLInputElement) => [field.selectionStart, field.selectionEnd])).toEqual([1, 1]);

    if (cdp) {
      await cdp.send("Input.insertText", { text: "é" });
    } else {
      await name.evaluate((field: HTMLInputElement) => {
        field.value = "é";
        field.setSelectionRange(1, 1);
        field.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "é" }));
        field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertFromComposition" }));
      });
    }
    await expect(history).toHaveText("input=é");
    await page.setViewportSize({ width: 500, height: 560 });
    expect(await name.evaluate((field, previous) => field === previous, original)).toBe(true);
    expect(await name.evaluate((field: HTMLInputElement) => [field.selectionStart, field.selectionEnd])).toEqual([1, 1]);
    await expect(name).toHaveValue("é");

    const tab = browserName === "webkit" && process.platform === "darwin" ? "Alt+Tab" : "Tab";
    await page.keyboard.press(tab);
    await expect(open).toBeFocused();
    await page.keyboard.press("Space");
    await expect(open).toBeChecked();
    await expect(history).toHaveText("input=é | change=true");

    await page.getByRole("button", { name: "Toggle editing" }).click();
    await expect(name).toBeDisabled();
    await expect(open).toBeDisabled();
    await open.evaluate((input: HTMLInputElement) => input.click());
    await name.evaluate((input: HTMLInputElement) => input.focus());
    await page.keyboard.type("x");
    await expect(open).toBeChecked();
    await expect(name).toHaveValue("é");
    await expect(history).toHaveText("input=é | change=true");
    expect(requests.filter(request => request.endsWith("/mochi-editing.js"))).toHaveLength(1);
  });
});

test("portable editor commits a real browser clipboard paste once", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Playwright clipboard permissions require Chromium");
  await withCompiledProject(project, async url => {
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"], { origin: url });
    await page.goto(url);
    const name = page.getByRole("textbox", { name: "Station name" });
    await expect(name).toHaveValue("Harbor");
    await page.evaluate(() => navigator.clipboard.writeText("East"));
    await name.focus();
    await name.evaluate((field: HTMLInputElement) => field.select());
    await page.keyboard.press(process.platform === "darwin" ? "Meta+V" : "Control+V");
    await expect(name).toHaveValue("East");
    await expect(page.locator("[data-view=history]")).toHaveText("input=East");
  });
});
