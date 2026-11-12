import { test, expect } from "@playwright/test";
import { withFrameworkProject } from "./framework_helpers";

test("compiled Ruby child props update through an interactive parent", async ({ page }) => {
  const pageErrors: string[] = [];
  const mochiErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.addInitScript(() => {
    window.addEventListener("mochi:error", (event) => {
      const detail = (event as CustomEvent).detail;
      (window as any).__contractMochiErrors.push(detail?.message || JSON.stringify(detail));
    });
    (window as any).__contractMochiErrors = [];
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("contract-root");
    const label = root.locator("contract-child .child-label");
    await expect(label).toHaveText("before");
    await root.locator("button.change").click();
    await expect(label).toHaveText("after");
    mochiErrors.push(...await page.evaluate(() => (window as any).__contractMochiErrors));
  });

  expect(pageErrors).toEqual([]);
  expect(mochiErrors).toEqual([]);
});

test("root conditional anchors render, toggle nested branches, and support initial true", async ({ page }) => {
  const runtimeErrors: string[] = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__errors = [];
    window.addEventListener("mochi:error", (event) => (window as any).__errors.push((event as CustomEvent).detail));
  });
  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("conditional-root");
    await expect(root.locator(".hidden")).toHaveText("Hidden");
    await root.locator(".toggle").click();
    await expect(root.locator(".visible")).toHaveText("Visible");
    await expect(root.locator(".nested")).toHaveText("Nested");
    await root.locator(".toggle").click();
    await expect(root.locator(".hidden")).toHaveText("Hidden");
    const initiallyOpen = await page.evaluate(async () => {
      const element = document.createElement("initially-open-conditional");
      document.body.appendChild(element);
      await (element as any)._mochiReady;
      return element.shadowRoot.textContent;
    });
    expect(initiallyOpen).toContain("Initially visible");
    expect(await page.evaluate(() => (window as any).__errors)).toEqual([]);
  });
  expect(runtimeErrors).toEqual([]);
});
