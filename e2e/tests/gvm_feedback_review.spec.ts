import { test, expect } from '@playwright/test';
import path from 'node:path';
import { withCompiledProject } from './framework_helpers';
const fixture = path.resolve(__dirname, '../fixtures/feedback_review');

test('feedback: 118 authored methods and 140 generated getters stay correct across instances and remounts', async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if(message.type() === 'error') errors.push(message.text()); });
  await page.addInitScript(() => {
    (window as any).__mochiErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__mochiErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const first = page.locator('binding-boundary.first');
    const second = page.locator('binding-boundary.second');
    await expect(first.locator('.seed')).toHaveText('10');
    await expect(first.locator('[data-slot="0"]')).toHaveText('10');
    await expect(first.locator('[data-slot="139"]')).toHaveText('149');
    await expect(second.locator('.seed')).toHaveText('20');
    await expect(second.locator('[data-slot="139"]')).toHaveText('159');
    await expect(first.locator('.boundary-row').first()).toHaveAttribute('data-row', 'a');
    await first.locator('[data-row="a"] .action').click();
    await expect(first.locator('.last-event')).toHaveText('Alpha');
    await expect(first.locator('.event-count')).toHaveText('1');
    await expect(second.locator('.last-event')).toHaveText('none');

    await page.locator('.replace-boundary-inputs').click();
    await expect(first.locator('.seed')).toHaveText('30');
    await expect(first.locator('[data-slot="139"]')).toHaveText('169');
    await expect(second.locator('.seed')).toHaveText('70');
    await expect(second.locator('[data-slot="139"]')).toHaveText('209');
    await expect(first.locator('.boundary-row').first()).toHaveAttribute('data-row', 'b');
    await expect(first.locator('[data-row="a"] .row-label')).toHaveText('Alpha2');
    await second.locator('[data-row="b"] .action').click();
    await expect(second.locator('.last-event')).toHaveText('Beta2');
    await expect(second.locator('.event-count')).toHaveText('1');
    await expect(first.locator('.last-event')).toHaveText('Alpha');

    await first.locator('.toggle-rows').click();
    await expect(first.locator('.boundary-row')).toHaveCount(0);
    await expect(second.locator('.boundary-row')).toHaveCount(2);
    await first.locator('.toggle-rows').click();
    await expect(first.locator('[data-row="a"] .row-label')).toHaveText('Alpha2');
    await first.locator('[data-row="a"] .action').click();
    await expect(first.locator('.last-event')).toHaveText('Alpha2');
    await expect(first.locator('.event-count')).toHaveText('2');
    await expect(second.locator('.last-event')).toHaveText('Beta2');
    expect(errors).toEqual([]);
    expect(await page.evaluate(() => (window as any).__mochiErrors)).toEqual([]);
  }, '<binding-boundary-host></binding-boundary-host>');
});

test('feedback: nested typed children retain both event connections across updates and remounts', async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => { if(m.type() === 'error') errors.push(m.text()); });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator('.boundary-count-256')).toHaveText('255');
    await expect(page.locator('.boundary-count-257')).toHaveText('256');
    await expect(page.locator('.boundary-count-260')).toHaveText('259');
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

test('feedback: binding failures name unsupported helper and preserve binding context for recovery', async ({page}) => {
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator('.diagnostic')).toHaveText('ready');
    const detail = page.evaluate(() => new Promise(resolve => {
      document.addEventListener('mochi:error', event => resolve((event as CustomEvent).detail), {once:true});
    }));
    await page.locator('.fail-helper').click();
    const failure: any = await detail;
    expect(failure.method).not.toContain('__mochi_bind');
    expect(failure.source).toContain('ReviewRoot.rb:');
    expect(failure.vmText).toContain('fetch_missing_value');
    expect(failure.bindingContext).toContain('binding');
    expect(failure.bindingContext).toContain('ReviewRoot.rb:');
    await page.locator('.recover-helper').click();
    await expect(page.locator('.diagnostic')).toHaveText('ready');
  }, '<review-root></review-root>');
});

test('feedback: is_a? matches Ruby value classes across VM zones, props, inheritance, and recovery', async ({page}) => {
  await page.addInitScript(() => {
    (window as any).__mochiErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__mochiErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const expected = 'true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true';
    await expect(page.locator('.init')).toHaveText(expected);
    await expect(page.locator('.binding')).toHaveText(expected);
    await page.locator('.check').click();
    await expect(page.locator('.event')).toHaveText(expected);

    await page.locator('.bad-arity').click();
    await expect.poll(async () => page.evaluate(() => (window as any).__mochiErrors.length)).toBe(1);
    let errors = await page.evaluate(() => (window as any).__mochiErrors);
    expect(errors[0].phase).toBe('event');
    expect(errors[0].source).toContain('TypeInspection.rb:');
    expect(errors[0].vmText).toContain('wrong number of arguments');

    await page.locator('.check').click();
    await expect(page.locator('.event')).toHaveText(expected);
    await page.locator('.bad-type').click();
    await expect.poll(async () => page.evaluate(() => (window as any).__mochiErrors.length)).toBe(2);
    errors = await page.evaluate(() => (window as any).__mochiErrors);
    expect(errors[1].source).toContain('TypeInspection.rb:');
    expect(errors[1].vmText).toContain('type mismatch');
    await page.locator('.check').click();
    await expect(page.locator('.event')).toHaveText(expected);
  }, '<type-inspection items="[]" meta="{}"></type-inspection>');
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

test('feedback: timers cancel and storage survives reload', async ({page}) => {
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
    await page.locator('.start').click();
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(1);
    await page.locator('review-root').evaluate(el => el.remove());
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
  }, '<review-root></review-root>');
});

test('feedback: removing a conditional child while its descriptor is pending never mounts it later', async ({page}) => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => release = resolve);
  await page.route('**/components/review-child.json', async route => { await gate; await route.continue(); });
  await withCompiledProject(fixture, async url => {
    await page.goto(url, {waitUntil:'domcontentloaded'});
    await expect(page.locator('review-child')).toHaveCount(0);
    await page.locator('.toggle').click();
    release();
    await expect(page.locator('review-child')).toHaveCount(0);
    await page.locator('.toggle').click();
    await expect(page.locator('[data-row="a"] .action')).toBeVisible();
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
