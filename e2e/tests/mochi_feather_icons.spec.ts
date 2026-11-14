import { getTestPage, setupConsoleLogging } from "./test_utils";

const { test, expect } = require('@playwright/test');

const testPageName = "feather_icons.html";

test.describe('Feather icon component', () => {
    test('renders both component instances', async ({ page }) => {
        setupConsoleLogging(page);
        await page.goto(getTestPage(testPageName));

        await expect(page.locator('feather-icon')).toHaveCount(2);
    });

    test('coffee icon uses the emitted selected asset', async ({ page }) => {
        setupConsoleLogging(page);
        await page.goto(getTestPage(testPageName));

        const coffeeIcon = page.locator('feather-icon').nth(0);
        await expect(coffeeIcon).toHaveAttribute('icon', 'coffee');
        await expect(coffeeIcon.locator('div.feather-icon')).toBeVisible();

        const svg = coffeeIcon.locator('svg.icon');
        await expect(svg).toBeVisible();
        await expect(svg).toHaveAttribute('viewBox', '0 0 24 24');
        await expect(svg.locator('use')).toHaveAttribute('href', /mochi-icons\/coffee\.svg#mochi-icon$/);
    });

    test('align-justify icon uses its own selected asset', async ({ page }) => {
        setupConsoleLogging(page);
        await page.goto(getTestPage(testPageName));

        const alignIcon = page.locator('feather-icon').nth(1);
        await expect(alignIcon).toHaveAttribute('icon', 'align-justify');
        await expect(alignIcon.locator('svg.icon use')).toHaveAttribute('href', /mochi-icons\/align-justify\.svg#mochi-icon$/);
    });

    test('does not require a global Feather library', async ({ page }) => {
        setupConsoleLogging(page);
        await page.goto(getTestPage(testPageName));

        const featherAvailable = await page.evaluate(() => typeof (window as any).feather !== "undefined");
        expect(featherAvailable).toBe(false);
    });
});
