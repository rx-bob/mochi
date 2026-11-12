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
