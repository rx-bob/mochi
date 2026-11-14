import { test, expect } from '@playwright/test';
import path from 'node:path';
import { withCompiledProject } from './framework_helpers';
const fixture = path.resolve(__dirname, '../fixtures/feedback_review');
const preferenceKey = 'mochi_e4s2_preferences';

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

test('feedback: raw ranges compose as direct nodes and preserve keyed siblings across replacement and disposal', async ({page}) => {
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator('raw-composition-root');
    const mixed = root.locator('.raw-mixed');
    const tags = () => mixed.evaluate(element => Array.from(element.children).map(child => child.tagName.toLowerCase()));
    const rowA = root.locator('[data-row="a"]');
    const rowAHandle = await rowA.elementHandle();
    const childAHandle = await rowA.locator('review-child').elementHandle();
    const draft = rowA.locator('.draft');

    await expect(mixed).toHaveText('Before after');
    expect(await tags()).toEqual(['svg']);
    expect(await root.locator('.raw-cell').evaluate(element => Array.from(element.children).map(child => child.tagName.toLowerCase())))
      .toEqual(['b', 'em']);
    await expect(root.locator('.raw-cell > b.table-value')).toHaveText('table');
    await expect(root.locator('.user-label')).toHaveText('<img class="untrusted" src=x onerror="bad()">');
    expect(await root.locator('.user-label img').count()).toBe(0);
    expect(await rowA.evaluate(element => element.querySelector(':scope > .row-mark')?.textContent)).toBe('A');
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().elements)).toBe(3);

    await draft.fill('unsaved draft');
    await draft.focus();
    await root.locator('.update-raw').evaluate(element => (element as HTMLElement).click());
    expect(await tags()).toEqual(['svg', 'strong']);
    await expect(mixed).toHaveText('Before {not_a_binding} after');
    await expect(draft).toHaveValue('unsaved draft');
    await expect(draft).toBeFocused();
    expect(await rowAHandle!.evaluate((element: any) => element.isConnected &&
      element === document.querySelector('raw-composition-root')!.shadowRoot!.querySelector('[data-row="a"]'))).toBe(true);
    expect(await childAHandle!.evaluate((element: any) => element.isConnected &&
      element === document.querySelector('raw-composition-root')!.shadowRoot!.querySelector('[data-row="a"] review-child'))).toBe(true);

    await rowA.locator('.action').click();
    await expect(root.locator('.selected')).toHaveText('Alpha');
    await root.locator('.reorder').click();
    expect(await rowAHandle!.evaluate((element: any) => element.isConnected &&
      element === document.querySelector('raw-composition-root')!.shadowRoot!.querySelector('[data-row="a"]'))).toBe(true);
    expect(await childAHandle!.evaluate((element: any) => element.isConnected &&
      element === document.querySelector('raw-composition-root')!.shadowRoot!.querySelector('[data-row="a"] review-child'))).toBe(true);
    expect(await rowA.locator('.draft').inputValue()).toBe('unsaved draft');

    await root.locator('.update-raw').evaluate(element => (element as HTMLElement).click());
    expect(await tags()).toEqual([]);
    expect(await mixed.evaluate(element => element.textContent)).toBe('Before  after');
    await root.locator('.update-raw').evaluate(element => (element as HTMLElement).click());
    expect(await tags()).toEqual(['svg', 'strong']);
    await root.locator('.update-raw').evaluate(element => (element as HTMLElement).click());
    expect(await tags()).toEqual([]);

    await root.locator('.toggle-rows').click();
    await expect(root.locator('review-child')).toHaveCount(0);
    await expect(root.locator('.row-mark')).toHaveCount(0);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().elements)).toBe(1);
    expect(await tags()).toEqual([]);
    await root.locator('.toggle-rows').click();
    await expect(root.locator('review-child')).toHaveCount(2);
    await expect(root.locator('.row-mark')).toHaveCount(2);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().elements)).toBe(3);
  }, '<raw-composition-root></raw-composition-root>');
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
    const expected = 'true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true';
    await expect(page.locator('.init')).toHaveText(expected);
    await expect(page.locator('.binding')).toHaveText(expected);
    await expect(page.locator('.each-type')).toHaveText(['true', 'true']);
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
  }, '<type-inspection items="[1,1099511627776]" meta="{}"></type-inspection>');
});

test('feedback: unshift preserves order and prop snapshots while root replacement renders', async ({page}) => {
  const errors: unknown[] = [];
  await page.addInitScript(() => {
    (window as any).__mochiErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__mochiErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator('unshift-root');
    await expect(root.locator('.root-values')).toHaveText('1,2,3');
    await expect(root.locator('.alias-values')).toHaveText('1,2,3');
    await expect(root.locator('.child-values')).toHaveText('1,2,3');

    await root.locator('.child-prepend').click();
    await expect(root.locator('.child-values')).toHaveText('8,1,2,3');
    await expect(root.locator('.root-values')).toHaveText('1,2,3');

    await root.locator('.root-prepend').click();
    await expect(root.locator('.root-values')).toHaveText('0,4,5,1,2,3');
    await expect(root.locator('.alias-values')).toHaveText('4,5,1,2,3');
    await expect(root.locator('.child-values')).toHaveText('0,4,5,1,2,3');
    errors.push(...await page.evaluate(() => (window as any).__mochiErrors));
    expect(errors).toEqual([]);
  }, '<unshift-root></unshift-root>');
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

test('feedback: structured preferences load before render, follow storage changes, and unsubscribe on disposal', async ({page}) => {
  const initial = '{"theme":"dark","density":"compact"}';
  await page.addInitScript(({key, value}) => {
    if (localStorage.getItem(key) === null) localStorage.setItem(key, value);
  }, {key: preferenceKey, value: initial});
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator('storage-root');
    await expect(root.locator('.theme')).toHaveText('dark');
    await expect(root.locator('.density')).toHaveText('compact');
    await expect(root.locator('.status')).toHaveText('loaded');
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().storageSubscribers)).toBe(1);

    await root.locator('.save').click();
    await expect(root.locator('.status')).toHaveText('loaded');
    await expect(root.locator('.theme')).toHaveText('light');
    await expect.poll(() => page.evaluate(key => localStorage.getItem(key), preferenceKey))
      .toBe('{"theme":"light","density":"comfortable"}');
    await page.reload();
    await expect(page.locator('storage-root .theme')).toHaveText('light');
    await expect(page.locator('storage-root .density')).toHaveText('comfortable');

    await page.evaluate(key => {
      const value = '{"theme":"dark","density":"compact"}';
      localStorage.setItem(key, value);
      window.dispatchEvent(new StorageEvent('storage', {
        key, oldValue: '{"theme":"light","density":"comfortable"}',
        newValue: value, storageArea: localStorage,
      }));
    }, preferenceKey);
    await expect(page.locator('storage-root .theme')).toHaveText('dark');
    await page.evaluate(key => {
      const oldValue = localStorage.getItem(key);
      localStorage.removeItem(key);
      window.dispatchEvent(new StorageEvent('storage', {
        key, oldValue, newValue: null, storageArea: localStorage,
      }));
    }, preferenceKey);
    await expect(page.locator('storage-root .theme')).toHaveText('light');
    await page.locator('storage-root').evaluate(element => element.remove());
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().storageSubscribers)).toBe(0);
    await page.evaluate(key => {
      localStorage.setItem(key, '{"theme":"dark","density":"compact"}');
      window.dispatchEvent(new StorageEvent('storage', {
        key, oldValue: null, newValue: localStorage.getItem(key), storageArea: localStorage,
      }));
    }, preferenceKey);
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().storageSubscribers)).toBe(0);
  }, '<storage-root></storage-root>');
});

test('feedback: malformed stored preferences use validated defaults and repair storage', async ({page}) => {
  await page.addInitScript(({key}) => localStorage.setItem(key, '{"theme":'), {key: preferenceKey});
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator('storage-root .theme')).toHaveText('light');
    await expect(page.locator('storage-root .density')).toHaveText('comfortable');
    await expect.poll(() => page.evaluate(key => localStorage.getItem(key), preferenceKey))
      .toBe('{"theme":"light","density":"comfortable"}');
  }, '<storage-root></storage-root>');
});

test('feedback: quota failures restore persisted preferences and remain visible', async ({page}) => {
  await page.addInitScript(key => {
    const setItem = Storage.prototype.setItem;
    (window as any).__rejectPreferenceWrite = false;
    Storage.prototype.setItem = function(storageKey, value) {
      if (storageKey === key && (window as any).__rejectPreferenceWrite) {
        throw new DOMException('storage quota exceeded', 'QuotaExceededError');
      }
      return setItem.call(this, storageKey, value);
    };
  }, preferenceKey);
  await page.addInitScript(({key, value}) => localStorage.setItem(key, value), {
    key: preferenceKey, value: '{"theme":"dark","density":"compact"}',
  });
  await page.addInitScript(() => {
    (window as any).__storageErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__storageErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const root = page.locator('storage-root');
    await expect(root.locator('.theme')).toHaveText('dark');
    await page.evaluate(() => (window as any).__rejectPreferenceWrite = true);
    await root.locator('.save').click();
    await expect(root.locator('.status')).toHaveText('quota');
    await expect(root.locator('.theme')).toHaveText('dark');
    expect(await page.evaluate(key => localStorage.getItem(key), preferenceKey))
      .toBe('{"theme":"dark","density":"compact"}');
    await expect.poll(() => page.evaluate(() => (window as any).__storageErrors.length)).toBe(1);
    expect((await page.evaluate(() => (window as any).__storageErrors))[0].phase).toBe('storage');
    await root.locator('.save-current').click();
    await expect(root.locator('.status')).toHaveText('quota');

    await page.evaluate(() => (window as any).__rejectPreferenceWrite = false);
    await root.locator('.save').click();
    await expect(root.locator('.status')).toHaveText('loaded');
    await expect(root.locator('.theme')).toHaveText('light');
  }, '<storage-root></storage-root>');
});

test('feedback: inaccessible storage falls back and reports unavailable through subscription', async ({page}) => {
  await page.addInitScript(({key, value}) => {
    localStorage.setItem(key, value);
    const getItem = Storage.prototype.getItem;
    Storage.prototype.getItem = function(storageKey) {
      if (storageKey === key) throw new DOMException('storage access denied', 'SecurityError');
      return getItem.call(this, storageKey);
    };
  }, {key: preferenceKey, value: '{"theme":"dark","density":"compact"}'});
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect(page.locator('storage-root .theme')).toHaveText('light');
    await expect(page.locator('storage-root .density')).toHaveText('comfortable');
    await expect(page.locator('storage-root .status')).toHaveText('unavailable');
    await page.locator('storage-root').evaluate(element => element.remove());
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().storageSubscribers)).toBe(0);
  }, '<storage-root></storage-root>');
});

test('feedback: mount-owned timers fire once, repeat, cancel, and dispose', async ({page}) => {
  const errors: any[] = [];
  await page.addInitScript(() => {
    (window as any).__timerErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__timerErrors.push((event as CustomEvent).detail);
    });
  });
  await page.clock.pauseAt(new Date('2026-01-01T00:00:00Z'));
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const timer = page.locator('timer-root');
    await expect(timer.locator('.ticks')).toHaveText('0');

    await timer.locator('.once').click();
    await page.clock.runFor(0);
    await expect(timer.locator('.ticks')).toHaveText('1');
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);

    await timer.locator('.start').click();
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(1);
    await page.clock.runFor(35);
    await timer.locator('.stop').click();
    const stoppedAt = await timer.locator('.ticks').textContent();
    expect(Number(stoppedAt)).toBeGreaterThan(1);
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
    await page.clock.fastForward(50);
    await expect(timer.locator('.ticks')).toHaveText(stoppedAt!);

    await timer.locator('.start').click();
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(1);
    const reusedTimer = await timer.elementHandle();
    await timer.evaluate(element => element.remove());
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
    await page.evaluate(element => document.body.appendChild(element), reusedTimer);
    await expect(timer.locator('.ticks')).toHaveText('0');
    await page.clock.fastForward(50);
    await expect(timer.locator('.ticks')).toHaveText('0');
    expect(await page.evaluate(() => (window as any).__timerErrors)).toEqual([]);
  }, '<timer-root></timer-root>');
  expect(errors).toEqual([]);
});

test('feedback: invalid timer calls fail at their Ruby method and allocate no timer', async ({page}) => {
  await page.addInitScript(() => {
    (window as any).__timerErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__timerErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const timer = page.locator('timer-root');
    for (const [button, expected] of [
      ['.bad-delay', 'timer delay'],
      ['.bad-delay-type', 'type mismatch'],
      ['.long-delay', 'timer delay'],
      ['.bad-callback', 'timer callback'],
      ['.bad-callback-type', 'timer callback'],
      ['.bad-callback-arity', 'wrong number of arguments'],
      ['.bad-handle', 'timer handle'],
    ]) {
      await timer.locator(button).click();
      await expect.poll(() => page.evaluate(() => (window as any).__timerErrors.length)).toBeGreaterThan(0);
      const errors = await page.evaluate(() => (window as any).__timerErrors);
      const error = errors[errors.length - 1];
      expect(error.message).toContain(expected);
      expect(error.source).toMatch(/TimerRoot\.rb:\d+/);
      expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
    }
  }, '<timer-root></timer-root>');
});

test('feedback: timer callback errors keep Ruby source and later callbacks recover', async ({page}) => {
  await page.addInitScript(() => {
    (window as any).__timerErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__timerErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    const timer = page.locator('timer-root');
    await timer.locator('.fail-once').click();
    await expect.poll(() => page.evaluate(() => (window as any).__timerErrors.length), { timeout: 1000 }).toBe(1);
    const error = await page.evaluate(() => (window as any).__timerErrors[0]);
    expect(error.phase).toBe('timer');
    expect(error.message).toContain('division by zero');
    expect(error.source).toMatch(/TimerRoot\.rb:\d+/);
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);

    await timer.locator('.once').click();
    await expect(timer.locator('.ticks')).toHaveText('1');
    expect(await page.evaluate(() => (window as any).__timerErrors.length)).toBe(1);
  }, '<timer-root></timer-root>');
});

test('feedback: a failed initializer drops its pending timer registration', async ({page}) => {
  await page.addInitScript(() => {
    (window as any).__timerErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__timerErrors.push((event as CustomEvent).detail);
    });
  });
  await withCompiledProject(fixture, async url => {
    await page.goto(url);
    await expect.poll(() => page.evaluate(() => (window as any).__timerErrors.length)).toBe(1);
    const error = await page.evaluate(() => (window as any).__timerErrors[0]);
    expect(error.source).toMatch(/TimerRoot\.rb:\d+/);
    expect(error.phase).toBe('mount');
    expect(await page.evaluate(() => (window as any).MochiLoader.debugStats().timers)).toBe(0);
  }, '<timer-failure></timer-failure>');
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

test('feedback: layout snapshots follow delayed CSS, resize and panel removal; display contents keeps shortcut scope in ancestry', async ({page}) => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => release = resolve);
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.addInitScript(() => {
    (window as any).__layoutErrors = [];
    document.addEventListener('mochi:error', event => {
      (window as any).__layoutErrors.push((event as CustomEvent).detail);
    });
  });
  await page.route('**/components/slow-panel.json', async route => { await gate; await route.continue(); });
  await withCompiledProject(fixture, async url => {
    let rootHandle: any;
    try {
      await page.goto(url, {waitUntil:'domcontentloaded'});
      const root = page.locator('layout-root');
      rootHandle = await root.elementHandle();
      await expect(root.locator('.geometry')).toHaveText('800');
      await expect.poll(() => root.locator('.geometry').getAttribute('data-width')).toBe('800');
      const initial = await root.locator('.viewport').evaluate(el => {
        const rect = el.getBoundingClientRect();
        return { width: rect.width, height: rect.height, left: rect.left, top: rect.top };
      });
      expect(initial.width).toBe(800);
      expect(initial.height).toBe(100);
      expect(Number(await root.locator('.geometry').getAttribute('data-center-x'))).toBeCloseTo(initial.left + initial.width / 2);
      expect(Number(await root.locator('.geometry').getAttribute('data-center-y'))).toBeCloseTo(initial.top + initial.height / 2);
    } finally { release(); }
    const root = page.locator('layout-root');
    const geometry = root.locator('.geometry');
    const expectMeasuredWidth = async (width: number) => {
      await expect.poll(async () => Number(await geometry.getAttribute('data-width'))).toBe(width);
      const rect = await root.locator('.viewport').evaluate(el => {
        const box = el.getBoundingClientRect();
        return { width: box.width, height: box.height, left: box.left, top: box.top };
      });
      expect(rect.width).toBe(width);
      expect(Number(await geometry.getAttribute('data-height'))).toBe(rect.height);
      expect(Number(await geometry.getAttribute('data-center-x'))).toBeCloseTo(rect.left + rect.width / 2);
      expect(Number(await geometry.getAttribute('data-center-y'))).toBeCloseTo(rect.top + rect.height / 2);
    };
    await expect(geometry).toHaveText('600');
    await expectMeasuredWidth(600);

    await root.locator('.frame').evaluate(el => { (el as HTMLElement).style.width = '1000px'; });
    await expectMeasuredWidth(800);
    await root.locator('.remove-panel').click();
    await expectMeasuredWidth(1000);
    await root.locator('.frame').evaluate(el => { (el as HTMLElement).style.width = '700px'; });
    await expectMeasuredWidth(700);

    await root.locator('.inside').focus();
    await page.keyboard.press('h');
    await expect(root.locator('.keys')).toHaveText('1');
    await page.locator('#outside').focus();
    await page.keyboard.press('h');
    await expect(root.locator('.keys')).toHaveText('1');

    await page.evaluate((element: any) => element.remove(), rootHandle);
    await expect.poll(() => page.evaluate(() => (window as any).MochiLoader.debugStats().elements)).toBe(0);
    await page.evaluate((element: any) => document.body.appendChild(element), rootHandle);
    await expectMeasuredWidth(600);
    await root.locator('.frame').evaluate(el => { (el as HTMLElement).style.width = '650px'; });
    await expectMeasuredWidth(450);
    await root.locator('.remove-panel').click();
    await expectMeasuredWidth(650);
    expect(await page.evaluate(() => (window as any).__layoutErrors)).toEqual([]);
    expect(errors).toEqual([]);
  }, '<div class="bridge"><button id="outside">Outside</button></div><layout-root></layout-root>');
});
