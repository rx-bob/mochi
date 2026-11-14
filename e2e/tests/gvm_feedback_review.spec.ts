import { test, expect } from '@playwright/test';
import path from 'node:path';
import { withCompiledProject } from './framework_helpers';
const fixture = path.resolve(__dirname, '../fixtures/feedback_review');

test('feedback: nested typed children retain both event connections across updates and remounts', async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => { if(m.type() === 'error') errors.push(m.text()); });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    for (let cycle=0;cycle<3;cycle++) {
      const row = page.locator('[data-row="a"]');
      await expect(row.locator('.label')).toHaveText(cycle ? 'Alpha2' : 'Alpha');
      // HTMLElement.click and a real click on nested text must both work.
      await row.locator('.action').evaluate((el: HTMLElement) => el.click());
      await expect(page.locator('output')).toHaveText(cycle ? 'Alpha2' : 'Alpha');
      await row.locator('.change').click();
      await expect(page.locator('output')).toHaveText(cycle ? 'A2' : 'A');
      await row.locator('.action span').click();
      await expect(page.locator('output')).toHaveText(cycle ? 'Alpha2' : 'Alpha');
      await expect(page.locator('.raw-body')).toHaveText('Review {literal} 3');
      await page.locator('.replace').click();
      await expect(page.locator('[data-row="a"] .label')).toHaveText('Alpha2');
      await page.locator('.toggle').click();
      await expect(page.locator('review-child')).toHaveCount(0);
      await page.locator('.toggle').click();
    }
    expect(errors).toEqual([]);
  }, '<review-root></review-root>');
});

test('feedback: dragstart inside conditional keyed rows registers without ancestor listener', async ({page}) => {
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const drag = page.locator('[data-row="a"] .drag');
    await expect(drag).toBeVisible();
    const text = await drag.evaluate(el => {
      const dataTransfer = new DataTransfer();
      el.dispatchEvent(new DragEvent('dragstart', {bubbles:true, composed:true, dataTransfer}));
      return dataTransfer.getData('text/plain');
    });
    expect(text).toBe('a');
    await expect(page.locator('output')).toHaveText('a');
    // No shadow boundary is crossed between a row and its own root delegate.
    const localText = await drag.evaluate(el => {
      const dataTransfer = new DataTransfer();
      el.dispatchEvent(new DragEvent('dragstart', {bubbles:true, composed:false, dataTransfer}));
      return dataTransfer.getData('text/plain');
    });
    expect(localText).toBe('a');
  }, '<review-root></review-root>');
});

test('feedback: delayed children use latest row props and work on first interaction', async ({page}) => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => release = resolve);
  await page.route('**/components/review-child.json', async route => { await gate; await route.continue(); });
  await withCompiledProject(fixture, async url => {
    try {
      await page.goto(url, {waitUntil:'domcontentloaded'});
      await page.locator('.replace').click();
      await expect(page.locator('review-child .action')).toHaveCount(0);
    } finally { release(); }
    await page.locator('[data-row="a"] .action').click();
    await expect(page.locator('output')).toHaveText('Alpha2');
  }, '<review-root></review-root>');
});

test('feedback: timers cancel and storage survives reload; raw markup introduces a wrapper', async ({page}) => {
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await page.locator('.start').click();
    await expect.poll(async () => Number(await page.locator('.ticks').textContent())).toBeGreaterThan(1);
    await page.locator('.stop').click();
    const before = await page.locator('.ticks').textContent();
    await page.waitForTimeout(100); // Deliberately cross several timer periods.
    await expect(page.locator('.ticks')).toHaveText(before!);
    await page.locator('.save').click();
    await page.reload();
    await page.locator('.read').click();
    await expect(page.locator('output')).toHaveText('saved');
    expect(await page.locator('.icon').evaluate(el => el.parentElement!.tagName)).toBe('SPAN');
    await page.locator('.start').click();
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(1);
    await page.locator('review-root').evaluate(el => el.remove());
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
  }, '<review-root></review-root>');
});

test('feedback: initial layout follows actual DOM while child CSS loads; display contents supports scoped shortcuts', async ({page}) => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => release = resolve);
  await page.route('**/components/slow-panel.json', async route => { await gate; await route.continue(); });
  await withCompiledProject(fixture, async url => {
    try {
      await page.goto(url, {waitUntil:'domcontentloaded'});
      await expect(page.locator('output')).toHaveText('800');
      expect(await page.locator('.viewport').evaluate(el => el.getBoundingClientRect().width)).toBe(800);
    } finally { release(); }
    await expect(page.locator('output')).toHaveText('600');
    expect(await page.locator('.viewport').evaluate(el => el.getBoundingClientRect().width)).toBe(600);
    await page.locator('.inside').focus();
    await page.keyboard.press('h');
    await expect(page.locator('.keys')).toHaveText('1');
    await page.locator('#outside').focus();
    await page.keyboard.press('h');
    await expect(page.locator('.keys')).toHaveText('1');
  }, '<button id="outside">Outside</button><layout-root></layout-root>');
});
