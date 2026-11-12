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

test("row attributes and handlers keep the current lexical scope through updates", async ({ page }) => {
  const pageErrors: string[] = [];
  const mochiErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__rowMochiErrors = [];
    window.addEventListener("mochi:error", (event) => {
      const detail = (event as CustomEvent).detail;
      (window as any).__rowMochiErrors.push(detail?.message || JSON.stringify(detail));
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("row-scope-root");
    const rows = root.locator("button.row");
    const classMap = root.locator("span[data-row]");
    await expect(rows.nth(0)).toHaveClass("row inactive");
    await expect(rows.nth(0)).toHaveText("Alpha!");
    await expect(rows.nth(0)).toHaveAttribute("title", "row-a");
    await expect(classMap.nth(0)).toHaveClass("selected zero");
    await expect(classMap.nth(1)).toHaveClass("");
    await rows.nth(1).click();
    await expect(root.locator("p.selected")).toHaveText("b:1");

    await root.locator("button.activate").click();
    await expect(rows.nth(0)).toHaveClass("row active");
    await root.evaluate((element: any) => element.shadowRoot.querySelector("button.reorder").click());
    await expect(rows.nth(0)).toHaveAttribute("data-row", "b");
    await rows.nth(0).click();
    await expect(root.locator("p.selected")).toHaveText("b:0");
    await root.locator("button.replace").click();
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toHaveAttribute("data-row", "c");
    await rows.first().click();
    await expect(root.locator("p.selected")).toHaveText("c:0");
    mochiErrors.push(...await page.evaluate(() => (window as any).__rowMochiErrors));
  }, "<row-scope-root></row-scope-root>");

  expect(pageErrors).toEqual([]);
  expect(mochiErrors).toEqual([]);
});

test("keyed table, select, and SVG rows use their insertion DOM context", async ({ page }) => {
  test.setTimeout(60_000);
  const pageErrors: string[] = [];
  const mochiErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__contextMochiErrors = [];
    window.addEventListener("mochi:error", (event) => {
      const detail = (event as CustomEvent).detail;
      (window as any).__contextMochiErrors.push(detail?.message || JSON.stringify(detail));
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("context-rows-root");
    const rows = root.locator("tbody tr[data-row]");
    const options = root.locator("select.options option");
    const paths = root.locator("svg path[data-row]");
    await expect(rows).toHaveCount(2);
    await expect(rows.nth(0).locator("td.label")).toHaveText("Alpha");
    await expect(options.nth(1)).toHaveText("Beta");
    await expect(paths.nth(0)).toHaveAttribute("fill", "red");

    const alphaRow = rows.nth(0);
    await alphaRow.evaluate((row) => { (window as any).__alphaRow = row; });
    const alphaInput = alphaRow.locator("input.draft");
    await alphaInput.fill("draft-alpha");
    await alphaInput.evaluate((input: HTMLInputElement) => input.setSelectionRange(2, 7));
    expect(await alphaInput.evaluate((input: HTMLInputElement) => {
      const root = input.getRootNode() as ShadowRoot;
      return root.activeElement === input;
    })).toBe(true);
    await root.evaluate((element: any) => {
      element.shadowRoot.querySelector("button.reorder").dispatchEvent(
        new MouseEvent("click", { bubbles: true, composed: true })
      );
    });
    await expect(rows.nth(0)).toHaveAttribute("data-row", "b");
    await expect(rows.nth(1)).toHaveAttribute("data-row", "a");
    expect(await rows.nth(1).evaluate((row) => row === (window as any).__alphaRow)).toBe(true);
    const movedAlpha = rows.nth(1);
    const movedInput = movedAlpha.locator("input.draft");
    await expect(movedInput).toHaveValue("draft-alpha");
    expect(await movedInput.evaluate((input: HTMLInputElement) => ({
      focused: input.getRootNode() instanceof ShadowRoot && (input.getRootNode() as ShadowRoot).activeElement === input,
      start: input.selectionStart,
      end: input.selectionEnd,
    }))).toEqual({ focused: true, start: 2, end: 7 });

    await root.locator("button.update").click();
    const updatedAlpha = root.locator('tbody tr[data-row="a"]');
    await expect(updatedAlpha.locator("td.label")).toHaveText("Alpine");
    await expect(root.locator("select option").filter({ hasText: "Bravo" })).toHaveCount(1);
    await expect(root.locator('svg path[data-row="a"]')).toHaveAttribute("fill", "green");
    await updatedAlpha.locator("button.choose").click();
    await expect(root.locator("p.selected")).toHaveText("a");
    await root.locator("button.replace").click();
    await expect(rows).toHaveCount(2);
    await expect(root.locator('tbody tr[data-row="a"]')).toHaveCount(0);
    await expect(root.locator('tbody tr[data-row="c"] td.label')).toHaveText("Charlie");
    await expect(root.locator('svg path[data-row="c"]')).toHaveAttribute("fill", "orange");
    await root.locator('tbody tr[data-row="c"] button.choose').click();
    await expect(root.locator("p.selected")).toHaveText("c");
    mochiErrors.push(...await page.evaluate(() => (window as any).__contextMochiErrors));
  }, "<context-rows-root></context-rows-root>");

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
    await page.evaluate(async () => {
      const element = document.createElement("conditional-root") as any;
      document.body.appendChild(element);
      await element._mochiReady;
    });
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

test("five siblings with four typed props mount independently across cold and cached class loads", async ({ page }) => {
  const runtimeErrors: string[] = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__errors = [];
    window.addEventListener("mochi:error", (event) => (window as any).__errors.push((event as CustomEvent).detail));
  });
  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    await page.evaluate(async () => {
      const pair = ["pair-a", "pair-b"].map((label, index) => {
        const element = document.createElement("child-probe") as any;
        element.setAttribute("label", label);
        element.setAttribute("remaining", String(10 + index));
        element.setAttribute("reset", "pair");
        document.body.appendChild(element);
        return element;
      });
      await Promise.all(pair.map((element) => element._mochiReady));
      pair.forEach((element) => element.remove());
    });
    const values = [
      { label: "A", remaining: "20", reset: "r0", tone: "normal" },
      { label: "B", remaining: "21", reset: "r1", tone: "normal" },
      { label: "C", remaining: "22", reset: "r2", tone: "normal" },
      { label: "D", remaining: "23", reset: "r3", tone: "normal" },
      { label: "E", remaining: "24", reset: "r4", tone: "normal" },
    ];
    await page.evaluate(async (props) => {
      const elements = props.slice().reverse().map((values) => {
        const element = document.createElement("child-probe");
        Object.entries(values).forEach(([key, value]) => element.setAttribute(key, value));
        document.body.appendChild(element);
        return element as any;
      });
      await Promise.all(elements.map((element) => element._mochiReady));
    }, values);
    const probes = page.locator("child-probe");
    await expect(probes).toHaveCount(5);
    for (const value of values) {
      const probe = probes.filter({ has: page.locator(`.probe[data-label="${value.label}"]`) });
      await expect(probe.locator(".probe")).toHaveText(`${value.remaining}%`);
      await expect(probe.locator(".probe")).toHaveAttribute("data-reset", value.reset);
    }

    const secondMount = await page.evaluate(async () => {
      const element = document.createElement("child-probe") as any;
      element.setAttribute("label", "late");
      element.setAttribute("remaining", "99");
      element.setAttribute("reset", "late-reset");
      element.setAttribute("tone", "cool");
      document.body.appendChild(element);
      await element._mochiReady;
      return true;
    });
    expect(secondMount).toBe(true);
    await expect(probes.last().locator(".probe")).toHaveText("99%");
    await probes.last().evaluate((element) => element.setAttribute("remaining", "100"));
    await expect(probes.last().locator(".probe")).toHaveText("100%");
    await expect(probes.nth(0).locator(".probe")).toHaveText("24%");
    const invalidFailure = await page.evaluate(async () => {
      const element = document.createElement("child-probe") as any;
      element.setAttribute("label", "invalid");
      element.setAttribute("remaining", "not-an-integer");
      element.setAttribute("reset", "invalid");
      document.body.appendChild(element);
      try { await element._mochiReady; return ""; }
      catch (error) { return String((error as Error).message); }
    });
    expect(invalidFailure).toContain('prop "remaining" expects an integer');
    await expect(probes.nth(0).locator(".probe")).toHaveText("24%");
    await page.evaluate(() => document.querySelector("child-probe[label='invalid']")?.remove());
    const retryText = await page.evaluate(async () => {
      const element = document.createElement("child-probe") as any;
      element.setAttribute("label", "retry");
      element.setAttribute("remaining", "88");
      element.setAttribute("reset", "retry");
      document.body.appendChild(element);
      await element._mochiReady;
      return element.shadowRoot.textContent;
    });
    expect(retryText).toContain("88%");
    expect(await page.evaluate(() => (window as any).__errors)).toEqual([]);
  });
  expect(runtimeErrors).toEqual([]);
});
