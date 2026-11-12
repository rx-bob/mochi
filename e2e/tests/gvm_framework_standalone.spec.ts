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

test("delayed child descriptor preserves cached props and healthy first render", async ({ page }) => {
  let requestSeen!: () => void;
  let releaseRequest!: () => void;
  const seen = new Promise<void>((resolve) => { requestSeen = resolve; });
  const released = new Promise<void>((resolve) => { releaseRequest = resolve; });
  await page.route("**/components/contract-child.json", async (route) => {
    requestSeen();
    await released;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      await seen;
      const root = page.locator("contract-root");
      const child = root.locator("contract-child");
      await root.evaluate((element: any) => element._mochiReady);
      await expect(root.locator("button.change")).toBeVisible();
      await expect(child).toHaveAttribute("label", "before");
      expect(await child.evaluate((element: any) => element._mochiMountState)).toBe("mounting");
      await root.locator("button.change").click();
      await expect(child).toHaveAttribute("label", "after");

      releaseRequest();
      await expect(child.locator(".child-label")).toHaveText("after");
    });
  } finally {
    releaseRequest();
  }
});

test("delayed sibling package does not block an independent first render", async ({ page }) => {
  let packageSeen!: () => void;
  let releasePackage!: () => void;
  const packageRequested = new Promise<void>((resolve) => { packageSeen = resolve; });
  const packageReleased = new Promise<void>((resolve) => { releasePackage = resolve; });
  await page.route("**/components/child-probe.chi", async (route) => {
    packageSeen();
    await packageReleased;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      await packageRequested;
      const root = page.locator("contract-root");
      const child = root.locator("contract-child");
      await root.evaluate((element: any) => element._mochiReady);
      await expect(child.locator(".child-label")).toHaveText("before");
      await expect(page.locator("child-probe")).toHaveJSProperty("_mochiMountState", "mounting");
      await root.locator("button.change").click();
      await expect(child.locator(".child-label")).toHaveText("after");

      releasePackage();
      await expect(page.locator("child-probe .probe")).toHaveText("37%");
    }, '<contract-root></contract-root><child-probe label="delayed-package" remaining="37" reset="cold"></child-probe>');
  } finally {
    releasePackage();
  }
});

test("one sibling descriptor failure does not strand healthy first-render bindings", async ({ page }) => {
  await page.route("**/components/child-probe.json", (route) =>
    route.fulfill({ status: 503, body: "descriptor unavailable" })
  );

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("contract-root");
    await expect(root.locator(".child-label")).toHaveText("before");
    const failed = await page.locator("child-probe").evaluate(async (element: any) => {
      try { await element._mochiReady; return { state: element._mochiMountState, error: "", childCount: element.shadowRoot.childNodes.length }; }
      catch (error) { return { state: element._mochiMountState, error: (error as Error).message, childCount: element.shadowRoot.childNodes.length }; }
    });
    expect(failed.state).toBe("failed");
    expect(failed.error).toContain("failed to fetch descriptor");
    expect(failed.childCount).toBe(0);
    await expect(root.locator(".child-label")).toHaveText("before");
  }, '<contract-root></contract-root><child-probe label="broken" remaining="37" reset="cold"></child-probe>');
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

test("Ruby-authored five-prop siblings survive controlled cold descriptor completion", async ({ page }) => {
  const runtimeErrors: string[] = [];
  let descriptorSeen!: () => void;
  let releaseDescriptor!: () => void;
  const seen = new Promise<void>((resolve) => { descriptorSeen = resolve; });
  const released = new Promise<void>((resolve) => { releaseDescriptor = resolve; });
  let descriptorRequests = 0;
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__siblingErrors = [];
    document.addEventListener("mochi:error", (event) => (window as any).__siblingErrors.push((event as CustomEvent).detail));
  });
  await page.route("**/components/child-probe.json", async (route) => {
    descriptorRequests += 1;
    descriptorSeen();
    await released;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      await seen;
      const root = page.locator("sibling-props-root");
      await root.evaluate((element: any) => element._mochiReady);
      const children = root.locator("child-probe");
      await expect(children).toHaveCount(5);
      expect(descriptorRequests).toBe(1);
      expect(await children.evaluateAll((elements: any[]) => elements.map((element) => element._mochiMountState)))
        .toEqual(["mounting", "mounting", "mounting", "mounting", "mounting"]);
      await children.nth(4).evaluate((element: any) => {
        element._mochiReady.catch(() => {});
        element.setAttribute("remaining", "not-an-integer");
      });

      releaseDescriptor();
      await root.evaluate(async (element: any) => {
        await Promise.allSettled(Array.from(element.shadowRoot.querySelectorAll("child-probe"))
          .map((child: any) => child._mochiReady));
      });
      for (const [index, label] of ["A", "B", "C", "D"].entries()) {
        const probe = children.nth(index).locator(".probe");
        await expect(probe).toHaveText(`${20 + index}%`);
        await expect(probe).toHaveAttribute("data-label", label);
        await expect(probe).toHaveAttribute("data-reset", `r${index}`);
        await expect(probe).toHaveAttribute("data-tone", "normal");
      }
      expect(await children.nth(4).evaluate((element: any) => element._mochiMountState)).toBe("failed");
      expect(await children.nth(4).evaluate((element: any) => element.shadowRoot.childNodes.length)).toBe(0);
      expect(await children.nth(4).evaluate((element: any) => element.mochiError.message))
        .toContain('prop "remaining" expects an integer');
      const retryText = await children.nth(4).evaluate(async (element: any) => {
        const parent = element.parentNode;
        element.remove();
        element.setAttribute("remaining", "24");
        parent.appendChild(element);
        await element._mochiReady;
        return element.shadowRoot.querySelector(".probe").textContent;
      });
      expect(retryText).toBe("24%");
      expect(await page.evaluate(() => (window as any).__siblingErrors.length)).toBe(1);
    }, "<sibling-props-root></sibling-props-root>");
  } finally {
    releaseDescriptor();
  }
  expect(runtimeErrors).toEqual([]);
});

test("typed Hash and Array props compose through static, conditional, and nested row mounts", async ({ page }) => {
  const runtimeErrors: string[] = [];
  const mochiErrors: string[] = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__groupedPropsErrors = [];
    document.addEventListener("mochi:error", (event) => {
      const detail = (event as CustomEvent).detail;
      (window as any).__groupedPropsErrors.push(detail?.message || String(detail));
    });
  });

  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("grouped-props-root");
    const children = root.locator("grouped-props-child");
    await expect(children).toHaveCount(4);
    const rowA = root.locator('grouped-props-child[data-item="a"] .typed-child');
    await expect(rowA).toHaveAttribute("data-label", "Alpha");
    await expect(rowA).toHaveAttribute("data-count", "0");
    await expect(rowA).toHaveAttribute("data-active", "false");
    await expect(rowA.locator(".initial-note")).toHaveText("north-a");
    await expect(rowA.locator(".note")).toHaveText("north-a");
    await expect(rowA.locator(".first-value")).toHaveText("a-value");
    await expect(rowA.locator(".summary")).toHaveText("Alpha:0");
    await expect(rowA.locator(".default-count")).toHaveText("0");
    await expect(rowA.locator(".setting-count")).toHaveText("0");
    await expect(root.locator('grouped-props-child[data-item="static"] .first-value')).toHaveText("static-value");

    await root.locator("button.open-inspector").click();
    const inspector = root.locator("props-inspector .inspector");
    const conditional = root.locator('grouped-props-child[data-item="conditional"] .typed-child');
    await expect(conditional.locator(".initial-note")).toHaveText("inspection");
    await expect(conditional).toHaveAttribute("data-count", "0");
    await expect(conditional).toHaveAttribute("data-active", "false");
    await expect(conditional.locator(".first-value")).toHaveText("static-value");
    await expect(inspector).toHaveAttribute("data-note", "inspection");
    await expect(inspector).toHaveAttribute("data-empty", "");
    await expect(inspector).toHaveAttribute("data-count", "0");
    await expect(inspector).toHaveAttribute("data-active", "false");

    await rowA.locator(".summary").evaluate((node) => {
      const changes: string[] = [];
      new MutationObserver(() => changes.push(node.textContent || "")).observe(node, {
        childList: true,
        characterData: true,
        subtree: true,
      });
      (window as any).__groupedSummaryChanges = changes;
    });
    await root.locator("button.update-pair").click();
    await expect(rowA).toHaveAttribute("data-label", "Alpine");
    await expect(rowA).toHaveAttribute("data-count", "4");
    await expect(rowA.locator(".note")).toHaveText("updated");
    await expect(rowA.locator(".summary")).toHaveText("Alpine:4");
    expect(await page.evaluate(() => (window as any).__groupedSummaryChanges)).toEqual(["Alpine:4"]);
    await expect(rowA.locator(".initial-note")).toHaveText("north-a");
    await expect(root.locator(".parent-note")).toHaveText("updated");
    await expect(inspector).toHaveAttribute("data-note", "updated-inspection");
    await expect(conditional.locator(".note")).toHaveText("updated-inspection");

    await rowA.locator("button.mutate").click();
    await expect(rowA.locator(".note")).toHaveText("child-only");
    await expect(rowA.locator(".first-value")).toHaveText("child-only");
    await expect(rowA.locator(".default-count")).toHaveText("1");
    await expect(rowA.locator(".setting-count")).toHaveText("1");
    await expect(root.locator(".parent-note")).toHaveText("updated");
    const rowB = root.locator('grouped-props-child[data-item="b"] .typed-child');
    await expect(rowB.locator(".note")).toHaveText("north-b");
    await expect(rowB.locator(".first-value")).toHaveText("b-value");
    await expect(rowB.locator(".default-count")).toHaveText("0");
    await expect(rowB.locator(".setting-count")).toHaveText("0");
    await expect(root.locator('grouped-props-child[data-item="static"] .default-count')).toHaveText("0");

    await root.locator("button.close-inspector").click();
    await expect(root.locator("props-inspector")).toHaveCount(0);
    const rowHost = root.locator('grouped-props-child[data-item="a"]');
    const rowInstance = await rowHost.evaluate((element: any) => element._mochiInstance);
    await rowHost.evaluate((element) => element.removeAttribute("label"));
    await expect.poll(() => page.evaluate(() => (window as any).__groupedPropsErrors.length)).toBe(1);
    await expect(rowHost.locator(".typed-child")).toHaveAttribute("data-label", "Alpine");
    expect(await rowHost.evaluate((element: any) => element._mochiInstance)).toBe(rowInstance);
    mochiErrors.push(...await page.evaluate(() => (window as any).__groupedPropsErrors.map((entry: any) => entry?.message || JSON.stringify(entry))));
    expect(mochiErrors).toHaveLength(1);
    expect(mochiErrors[0]).toContain("is required but the attribute was removed");
    expect(mochiErrors[0]).toContain("GroupedPropsRoot.rb");
  }, "<grouped-props-root></grouped-props-root>");

  expect(runtimeErrors).toEqual([]);
});

test("a nested typed child removed during package loading never mounts later", async ({ page }) => {
  let packageSeen!: () => void;
  let releasePackage!: () => void;
  const requested = new Promise<void>((resolve) => { packageSeen = resolve; });
  const released = new Promise<void>((resolve) => { releasePackage = resolve; });
  await page.route("**/components/grouped-props-child.json", async (route) => {
    packageSeen();
    await released;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      await requested;
      const root = page.locator("grouped-props-root");
      await expect(root.locator("button.clear-groups")).toBeVisible();
      const rowChildren = root.locator('grouped-props-child[data-item="a"], grouped-props-child[data-item="b"], grouped-props-child[data-item="c"]');
      await expect(rowChildren).toHaveCount(3);
      await rowChildren.evaluateAll((elements: any[]) => {
        (window as any).__removedRowChildren = elements;
      });
      await root.locator("button.clear-groups").click();
      await expect(rowChildren).toHaveCount(0);
      releasePackage();
      await expect(root.locator('grouped-props-child[data-item="static"] .typed-child')).toHaveAttribute("data-label", "Static");
      const removedStates = await page.evaluate(async () => {
        const elements = (window as any).__removedRowChildren as any[];
        await Promise.allSettled(elements.map((element) => element._mochiReady));
        return elements.map((element) => ({ state: element._mochiMountState, instance: element._mochiInstance }));
      });
      expect(removedStates).toEqual([
        { state: "unmounted", instance: null },
        { state: "unmounted", instance: null },
        { state: "unmounted", instance: null },
      ]);
      await expect(rowChildren).toHaveCount(0);
    }, "<grouped-props-root></grouped-props-root>");
  } finally {
    releasePackage();
  }
});

test("delayed nested child mounts use latest first-render props across rows and conditional branches", async ({ page }) => {
  let descriptorSeen!: () => void;
  let releaseDescriptor!: () => void;
  const requested = new Promise<void>((resolve) => { descriptorSeen = resolve; });
  const released = new Promise<void>((resolve) => { releaseDescriptor = resolve; });
  const runtimeErrors: string[] = [];
  const mochiErrors: string[] = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__delayedGroupedErrors = [];
    document.addEventListener("mochi:error", (event) => {
      const detail = (event as CustomEvent).detail;
      (window as any).__delayedGroupedErrors.push(detail?.message || String(detail));
    });
  });
  await page.route("**/components/grouped-props-child.json", async (route) => {
    descriptorSeen();
    await released;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      await requested;
      const root = page.locator("grouped-props-root");
      await expect(root.locator("button.update-pair")).toBeVisible();
      await root.locator("button.update-pair").click();
      await root.locator("button.open-inspector").click();
      const pendingRow = root.locator('grouped-props-child[data-item="a"]');
      const pendingConditional = root.locator('grouped-props-child[data-item="conditional"]');
      await expect(pendingRow).toHaveAttribute("label", "Alpine");
      await expect(pendingRow).toHaveAttribute("count", "4");
      await expect(pendingConditional).toHaveAttribute("metadata", /updated-inspection/);

      releaseDescriptor();
      await expect(pendingRow.locator(".typed-child")).toHaveAttribute("data-label", "Alpine");
      await expect(pendingRow.locator(".typed-child")).toHaveAttribute("data-count", "4");
      await expect(pendingRow.locator(".initial-note")).toHaveText("updated");
      await expect(pendingConditional.locator(".initial-note")).toHaveText("updated-inspection");
      await expect(pendingConditional.locator(".note")).toHaveText("updated-inspection");
      await expect(root.locator("props-inspector .inspector")).toHaveAttribute("data-note", "updated-inspection");
      mochiErrors.push(...await page.evaluate(() => (window as any).__delayedGroupedErrors));
      expect(mochiErrors).toEqual([]);
    }, "<grouped-props-root></grouped-props-root>");
  } finally {
    releaseDescriptor();
  }
  expect(runtimeErrors).toEqual([]);
});

test("a conditional child removed during descriptor loading stays unmounted", async ({ page }) => {
  let descriptorSeen!: () => void;
  let releaseDescriptor!: () => void;
  const requested = new Promise<void>((resolve) => { descriptorSeen = resolve; });
  const released = new Promise<void>((resolve) => { releaseDescriptor = resolve; });
  await page.route("**/components/props-inspector.json", async (route) => {
    descriptorSeen();
    await released;
    await route.continue();
  });

  try {
    await withFrameworkProject(async (baseURL) => {
      await page.goto(`${baseURL}/index.html`);
      const root = page.locator("grouped-props-root");
      await expect(root.locator("button.open-inspector")).toBeVisible();
      await root.locator("button.open-inspector").click();
      await requested;
      const inspector = root.locator("props-inspector");
      await expect(inspector).toHaveCount(1);
      await inspector.evaluate((element: any) => { (window as any).__removedInspector = element; });
      await root.locator("button.close-inspector").click();
      await expect(inspector).toHaveCount(0);
      releaseDescriptor();
      const state = await page.evaluate(async () => {
        const element = (window as any).__removedInspector;
        await element._mochiReady;
        return { state: element._mochiMountState, instance: element._mochiInstance, shadowChildren: element.shadowRoot.childNodes.length };
      });
      expect(state).toEqual({ state: "unmounted", instance: null, shadowChildren: 0 });
    }, "<grouped-props-root></grouped-props-root>");
  } finally {
    releaseDescriptor();
  }
});

test("keyed typed children keep local and editable state on moves, then release each mount", async ({ page }) => {
  const runtimeErrors: string[] = [];
  page.on("pageerror", (error) => runtimeErrors.push(error.message));
  await withFrameworkProject(async (baseURL) => {
    await page.goto(`${baseURL}/index.html`);
    const root = page.locator("keyed-state-root");
    const rows = root.locator("li.row");
    await expect(rows).toHaveCount(2);
    const originalA = root.locator('li[data-row="a"] keyed-state-child');
    await expect(originalA.locator(".child-label")).toHaveText("Alpha");
    await expect(originalA.locator(".local-count")).toHaveText("0");
    await expect(originalA.locator(".mount-count")).toHaveText("1");
    await originalA.evaluate((element: any) => { (window as any).__originalA = element; });
    const input = originalA.locator("input.draft");
    await input.fill("draft retained");
    await input.evaluate((element: HTMLInputElement) => element.setSelectionRange(3, 9));
    await input.focus();
    await originalA.locator("button.increment").click();
    await expect(originalA.locator(".local-count")).toHaveText("1");
    await input.focus();
    await input.evaluate((element: HTMLInputElement) => element.setSelectionRange(3, 9));
    const originalInstance = await originalA.evaluate((element: any) => element._mochiInstance);

    const activeBaseline = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    expect(activeBaseline.components).toBe(3);
    expect(activeBaseline.elements).toBe(3);

    await root.evaluate((element: any) => element.shadowRoot.querySelector("button.prepend").dispatchEvent(
      new MouseEvent("click", { bubbles: true, composed: true })
    ));
    await expect(rows).toHaveCount(3);
    await expect(rows.nth(1)).toHaveAttribute("data-row", "a");
    await root.evaluate((element: any) => element.shadowRoot.querySelector("button.reverse").dispatchEvent(
      new MouseEvent("click", { bubbles: true, composed: true })
    ));
    await expect(rows.nth(1)).toHaveAttribute("data-row", "a");
    await root.evaluate((element: any) => Promise.all(
      Array.from(element.shadowRoot.querySelectorAll("keyed-state-child")).map((child: any) => child._mochiReady)
    ));
    const cycleBaseline = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    expect(cycleBaseline.components).toBe(4);
    expect(cycleBaseline.elements).toBe(4);
    expect(cycleBaseline.routeSubscribers).toBeGreaterThan(0);
    expect(cycleBaseline.storageSubscribers).toBeGreaterThan(0);
    expect(cycleBaseline.storageSubscriptionKeys).toBeGreaterThan(0);
    const movedA = root.locator('li[data-row="a"] keyed-state-child');
    await expect(movedA.locator(".local-count")).toHaveText("1");
    await expect(root.locator('li[data-row="c"] .mount-count')).toHaveText("1");
    await expect(root.locator('li[data-row="b"] .mount-count')).toHaveText("1");
    await expect(movedA.locator(".mount-count")).toHaveText("1");
    expect(await movedA.evaluate((element: any) => element === (window as any).__originalA)).toBe(true);
    expect(await movedA.evaluate((element: any) => element._mochiInstance)).toBe(originalInstance);
    expect(await movedA.locator("input.draft").evaluate((element: HTMLInputElement) => ({
      value: element.value,
      focused: element.getRootNode() instanceof ShadowRoot && (element.getRootNode() as ShadowRoot).activeElement === element,
      start: element.selectionStart,
      end: element.selectionEnd,
    }))).toEqual({ value: "draft retained", focused: true, start: 3, end: 9 });

    let currentA = movedA;
    for (let cycle = 0; cycle < 3; cycle += 1) {
      await currentA.evaluate((element: any) => { (window as any).__removedA = element; });
      await root.locator("button.remove-a").click();
      await expect(rows).toHaveCount(2);
      await expect.poll(() => page.evaluate(() => (window as any).__removedA._mochiMountState)).toBe("unmounted");
      const disposed = await page.evaluate(() => ({
        ...((window as any).MochiLoader.debugStats()),
        instance: (window as any).__removedA._mochiInstance,
        bindingsCleared: Object.keys((window as any).__removedA.bindingTargets).length === 0,
      }));
      expect(disposed.components, JSON.stringify({ cycleBaseline, disposed })).toBe(cycleBaseline.components - 1);
      expect(disposed.elements).toBe(cycleBaseline.elements - 1);
      expect(disposed.bindings).toBeLessThan(cycleBaseline.bindings);
      expect(disposed.instance).toBeNull();
      expect(disposed.bindingsCleared).toBe(true);
      expect(disposed.timers).toBe(cycleBaseline.timers);
      expect(disposed.pendingHostRequests).toBe(cycleBaseline.pendingHostRequests);
      expect(disposed.routeSubscribers).toBeLessThan(cycleBaseline.routeSubscribers);
      expect(disposed.storageSubscribers).toBeLessThan(cycleBaseline.storageSubscribers);
      expect(disposed.storageSubscriptionKeys).toBeLessThan(cycleBaseline.storageSubscriptionKeys);
      expect(disposed.unmountedInstances).toBe(cycleBaseline.unmountedInstances);

      await root.locator("button.reinsert-a").click();
      currentA = root.locator('li[data-row="a"] keyed-state-child');
      await expect(currentA.locator(".local-count")).toHaveText("0");
      await expect(currentA.locator(".mount-count")).toHaveText("1");
      await expect(currentA.locator(".child-label")).toHaveText("Alpha fresh");
      const freshInstance = await currentA.evaluate((element: any) => element._mochiInstance);
      expect(freshInstance).not.toBe(originalInstance);
      const restored = await page.evaluate(() => (window as any).MochiLoader.debugStats());
      for (const key of ["components", "bindings", "elements", "timers", "pendingFetches", "activeFetches", "pendingHostRequests", "routeSubscribers", "storageSubscribers", "storageSubscriptionKeys", "unmountedInstances"]) {
        expect(restored[key], `${key} after lifecycle cycle ${cycle + 1}`).toBe(cycleBaseline[key]);
      }
    }
  }, "<keyed-state-root></keyed-state-root>");
  expect(runtimeErrors).toEqual([]);
});
