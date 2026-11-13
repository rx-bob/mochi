const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const playwright = require("playwright");

const [bundleDir, planPath, browserList = "chromium,firefox,webkit"] = process.argv.slice(2);
if (!bundleDir || !planPath) {
  console.error("usage: mochi_test_runner.cjs <bundle-dir> <test-plan.json> [browsers]");
  process.exit(2);
}

const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
};

function locate(root, selector) {
  const parts = selector.split(/\s*>>>\s*/).filter(Boolean);
  let scope = root;
  let found = null;
  for (let index = 0; index < parts.length; index += 1) {
    found = scope.querySelector(parts[index]);
    if (!found) return null;
    if (index + 1 < parts.length) {
      scope = found.shadowRoot;
      if (!scope) return null;
    }
  }
  return found;
}

function sourceLabel(step) {
  return `${step.source}:${step.line}`;
}

async function waitForPointerIdle(page) {
  await page.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  }));
  await page.waitForFunction(() => {
    const stats = window.MochiLoader.debugStats();
    return stats.pendingPointerMoves === 0;
  }, null, { timeout: 5000 });
}

async function runCase(browser, browserName, baseUrl, testCase) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.__mochiTestErrors = [];
    window.__mochiTestPointer = null;
    document.addEventListener("mochi:error", (event) => {
      window.__mochiTestErrors.push(event.detail || { message: "Mochi runtime error" });
    });
    document.addEventListener("pointerdown", (event) => {
      const path = typeof event.composedPath === "function" ? event.composedPath() : [];
      window.__mochiTestPointer = {
        id: event.pointerId,
        target: path.length > 0 ? path[0] : event.target,
      };
    }, true);
  });

  let host = null;
  let detachedHost = null;
  let expectedError = null;
  let activePointer = null;
  try {
    await page.goto(`${baseUrl}/`);
    await page.waitForFunction(() => window.MochiLoader && window.MochiLoader.manifest);

    for (const step of testCase.steps) {
      const origin = sourceLabel(step);
      if (step.operation === "mount") {
        if (host) throw new Error(`${origin}: each test can mount one root component`);
        await page.evaluate(({ tag, props }) => {
          const element = document.createElement(tag);
          Object.entries(props || {}).forEach(([name, value]) => {
            if (!/^[a-zA-Z][a-zA-Z0-9:_-]*$/.test(name)) {
              throw new Error(`invalid component input attribute '${name}'`);
            }
            if (value !== null && value !== undefined) {
              element.setAttribute(name, typeof value === "string" ? value : JSON.stringify(value));
            }
          });
          document.body.appendChild(element);
          return true;
        }, { tag: step.tag, props: step.props });
        host = step.tag;
        await page.evaluate(async (tag) => {
          const element = document.querySelector(tag);
          await element._mochiReady;
        }, host);
      } else if (["pointer_press", "pointer_move_by", "pointer_release", "pointer_cancel",
        "pointer_lose_capture", "assert_pointer_capture_released"].includes(step.operation)) {
        if (!host && step.operation !== "assert_pointer_capture_released") {
          throw new Error(`${origin}: mount a component before using ${step.operation}`);
        }
        if (step.operation === "pointer_press") {
          if (activePointer) throw new Error(`${origin}: release or cancel the current test pointer first`);
          const target = page.locator(host).locator(step.selector);
          const box = await target.boundingBox();
          if (!box) throw new Error(`${origin}: selector '${step.selector}' matched no visible element`);
          const x = Math.round(box.x + box.width / 2);
          const y = Math.round(box.y + box.height / 2);
          await page.mouse.move(x, y);
          await page.mouse.down();
          const pointer = await page.evaluate(() => window.__mochiTestPointer);
          if (!pointer) throw new Error(`${origin}: browser did not report pointerdown`);
          activePointer = { id: pointer.id, x, y };
          await waitForPointerIdle(page);
        } else if (step.operation === "pointer_move_by") {
          if (!activePointer) throw new Error(`${origin}: pointer_move_by requires pointer_press`);
          const steps = Number(step.steps);
          if (!Number.isInteger(steps) || steps < 1 || steps > 256) {
            throw new Error(`${origin}: pointer_move_by steps must be between 1 and 256`);
          }
          activePointer.x += Number(step.x);
          activePointer.y += Number(step.y);
          await page.mouse.move(activePointer.x, activePointer.y, { steps });
          await waitForPointerIdle(page);
        } else if (step.operation === "pointer_release") {
          if (!activePointer) throw new Error(`${origin}: pointer_release requires pointer_press`);
          await page.mouse.up();
          activePointer = null;
          await waitForPointerIdle(page);
        } else if (step.operation === "pointer_cancel") {
          if (!activePointer) throw new Error(`${origin}: pointer_cancel requires pointer_press`);
          await page.evaluate(({ id, x, y }) => {
            const pointer = window.__mochiTestPointer;
            if (!pointer || pointer.id !== id || !pointer.target || !pointer.target.isConnected) {
              throw new Error("test pointer target is no longer connected");
            }
            pointer.target.dispatchEvent(new PointerEvent("pointercancel", {
              bubbles: true, composed: true, pointerId: id, pointerType: "mouse",
              isPrimary: true, buttons: 0, clientX: x, clientY: y,
            }));
          }, activePointer);
          await page.mouse.up();
          activePointer = null;
          await waitForPointerIdle(page);
        } else if (step.operation === "pointer_lose_capture") {
          if (!activePointer) throw new Error(`${origin}: pointer_lose_capture requires pointer_press`);
          await page.evaluate((id) => {
            const pointer = window.__mochiTestPointer;
            if (!pointer || pointer.id !== id || !pointer.target ||
                typeof pointer.target.releasePointerCapture !== "function" ||
                !pointer.target.hasPointerCapture(id)) {
              throw new Error("test pointer has no live capture to release");
            }
            pointer.target.releasePointerCapture(id);
          }, activePointer.id);
          await waitForPointerIdle(page);
          await page.mouse.up();
          activePointer = null;
          await waitForPointerIdle(page);
        } else {
          const captured = await page.evaluate(() => {
            const pointer = window.__mochiTestPointer;
            return !!(pointer && pointer.target && pointer.target.hasPointerCapture &&
              pointer.target.hasPointerCapture(pointer.id));
          });
          if (captured) throw new Error(`${origin}: pointer capture remained active`);
        }
      } else if (["click", "fill", "assert_text", "assert_attribute", "assert_no_attribute", "assert_value"].includes(step.operation)) {
        if (!host) throw new Error(`${origin}: mount a component before using ${step.operation}`);
        const result = await page.evaluate(({ tag, step }) => {
          const element = document.querySelector(tag);
          const target = (() => {
            const parts = step.selector.split(/\s*>>>\s*/).filter(Boolean);
            let scope = element.shadowRoot;
            let found = null;
            for (let index = 0; index < parts.length; index += 1) {
              found = scope && scope.querySelector(parts[index]);
              if (!found) return null;
              if (index + 1 < parts.length) scope = found.shadowRoot;
            }
            return found;
          })();
          if (!target) return { missing: true };
          if (step.operation === "click") {
            target.click();
            return { ok: true };
          }
          if (step.operation === "fill") {
            if (!(target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement ||
                  target instanceof HTMLSelectElement)) {
              return { invalid: "target is not a form control" };
            }
            target.value = step.value;
            target.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
            target.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
            return { ok: true };
          }
          if (step.operation === "assert_attribute" || step.operation === "assert_no_attribute") {
            return { present: target.hasAttribute(step.name), actual: target.getAttribute(step.name) };
          }
          if (step.operation === "assert_value") return { actual: target.value };
          const actual = (target.innerText || target.textContent || "").trim();
          return { actual };
        }, { tag: host, step });

        if (result.missing) throw new Error(`${origin}: selector '${step.selector}' matched no visible element`);
        if (result.invalid) throw new Error(`${origin}: ${result.invalid}`);
        if (step.operation === "assert_attribute" && (!result.present || result.actual !== step.expected)) {
          throw new Error(`${origin}: expected attribute '${step.name}' to equal '${step.expected}', got ${result.present ? `'${result.actual}'` : "absent"}`);
        }
        if (step.operation === "assert_no_attribute" && result.present) {
          throw new Error(`${origin}: expected attribute '${step.name}' to be absent, got '${result.actual}'`);
        }
        if (step.operation === "assert_value" && result.actual !== step.expected) {
          throw new Error(`${origin}: expected value '${step.expected}' at '${step.selector}', got '${result.actual}'`);
        }
        if (step.operation === "assert_text" && result.actual !== step.expected) {
          throw new Error(`${origin}: expected '${step.expected}' at '${step.selector}', got '${result.actual}'`);
        }
      } else if (step.operation === "expect_error") {
        expectedError = step.message || "";
        continue;
      } else if (step.operation === "wait") {
        await page.waitForFunction(() => {
          const stats = window.MochiLoader.debugStats();
          return stats.pendingFetches === 0 && stats.activeFetches === 0 &&
            stats.pendingHostRequests === 0 && stats.pendingPointerMoves === 0;
        }, null, { timeout: 5000 });
        await page.evaluate(() => new Promise((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(resolve));
        }));
      } else if (step.operation === "unmount" || step.operation === "remount") {
        if (step.operation === "unmount" && !host) throw new Error(`${origin}: mount a component before unmount`);
        if (step.operation === "remount" && !host && !detachedHost && !step.tag) throw new Error(`${origin}: remount requires a prior unmount or component tag`);
        const targetTag = host || detachedHost || step.tag;
        await page.evaluate(({ tag, operation, nextTag, props }) => {
          const current = document.querySelector(tag);
          if (current) current.remove();
          if (operation === "remount") {
            const replacement = document.createElement(nextTag || tag);
            Object.entries(props || {}).forEach(([name, value]) => {
              if (value !== null && value !== undefined) replacement.setAttribute(name, typeof value === "string" ? value : JSON.stringify(value));
            });
            document.body.appendChild(replacement);
          }
        }, { tag: targetTag, operation: step.operation, nextTag: step.tag, props: step.props });
        if (step.operation === "unmount") {
          detachedHost = host;
          host = null;
          if (activePointer) {
            await waitForPointerIdle(page);
            const captured = await page.evaluate(() => {
              const pointer = window.__mochiTestPointer;
              return !!(pointer && pointer.target && pointer.target.hasPointerCapture &&
                pointer.target.hasPointerCapture(pointer.id));
            });
            if (captured) throw new Error(`${origin}: unmount left pointer capture active`);
            await page.mouse.up();
            activePointer = null;
          }
        }
        else {
          host = step.tag || detachedHost;
          detachedHost = null;
          await page.evaluate(async (tag) => { await document.querySelector(tag)._mochiReady; }, host);
        }
      } else {
        throw new Error(`${origin}: unsupported Ruby test operation '${step.operation}'`);
      }

      const runtimeErrors = await page.evaluate(() => window.__mochiTestErrors || []);
      if (runtimeErrors.length > 0) {
        const error = runtimeErrors[0];
        const where = error.source ? ` (${error.source})` : "";
        const message = error.message || JSON.stringify(error);
        if (!expectedError || (expectedError && !message.includes(expectedError))) {
          throw new Error(`${origin}: Mochi runtime error${where}: ${message}`);
        }
        expectedError = null;
      } else if (expectedError) {
        throw new Error(`${origin}: expected Mochi error containing '${expectedError}', but no error occurred`);
      }
      if (errors.length > 0) throw new Error(`${origin}: browser error: ${errors[0]}`);
    }
    console.log(`PASS [${browserName}] ${testCase.name}`);
    return true;
  } finally {
    await page.close();
  }
}

async function main() {
  const server = http.createServer((request, response) => {
    const pathname = decodeURIComponent((request.url || "/").split("?")[0]);
    const relative = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
    const filePath = path.resolve(bundleDir, relative);
    if (filePath !== bundleDir && !filePath.startsWith(bundleDir + path.sep)) {
      response.writeHead(403).end();
      return;
    }
    fs.readFile(filePath, (error, bytes) => {
      if (error) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, {
        "content-type": contentTypes[path.extname(filePath)] || "application/octet-stream",
      });
      response.end(bytes);
    });
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  let failed = false;
  try {
    const baseUrl = `http://127.0.0.1:${address.port}`;
    for (const browserName of browserList.split(",").map((name) => name.trim()).filter(Boolean)) {
      const browserType = playwright[browserName];
      let browser;
      try {
        browser = await browserType.launch({ headless: true });
      } catch (error) {
        console.error(`mochi test: ${browserName} is unavailable. Install with: npx playwright install ${browserName}\n${error.message}`);
        process.exitCode = 2;
        return;
      }
      try {
        for (const testCase of plan.tests || []) {
          try {
            await runCase(browser, browserName, baseUrl, testCase);
          } catch (error) {
            failed = true;
            console.error(`FAIL [${browserName}] ${testCase.name}: ${error.message}`);
          }
        }
      } finally {
        await browser.close();
      }
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
  if (failed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
