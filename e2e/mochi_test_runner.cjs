const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const playwright = require("playwright");

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
  return `${step.ruby_file}:${step.line}`;
}

function syntheticFiles(step) {
  if (!Array.isArray(step.files) || step.files.length === 0) {
    throw new Error(`${sourceLabel(step)}: files must be a non-empty Array`);
  }
  return step.files.map((spec) => {
    if (!spec || typeof spec !== "object" || Array.isArray(spec)) {
      throw new Error(`${sourceLabel(step)}: each test file must be a Hash`);
    }
    const hasPath = typeof spec.path === "string" && spec.path.length > 0;
    const hasBytes = Object.prototype.hasOwnProperty.call(spec, "bytes");
    if (hasPath === hasBytes) {
      throw new Error(`${sourceLabel(step)}: test file needs exactly one of path or bytes`);
    }
    let bytes;
    let defaultName;
    if (hasPath) {
      const filePath = path.resolve(path.dirname(step.ruby_file), spec.path);
      let stat;
      try {
        stat = fs.statSync(filePath);
      } catch (error) {
        throw new Error(`${sourceLabel(step)}: cannot read test file '${spec.path}': ${error.message}`);
      }
      if (!stat.isFile()) throw new Error(`${sourceLabel(step)}: test file path '${spec.path}' is not a file`);
      if (stat.size > 16 * 1024 * 1024) throw new Error(`${sourceLabel(step)}: test file exceeds the 16 MiB harness limit`);
      bytes = fs.readFileSync(filePath);
      defaultName = path.basename(filePath);
    } else if (typeof spec.bytes === "string") {
      if (Buffer.byteLength(spec.bytes, "utf8") > 16 * 1024 * 1024) {
        throw new Error(`${sourceLabel(step)}: test file exceeds the 16 MiB harness limit`);
      }
      bytes = Buffer.from(spec.bytes, "utf8");
    } else if (Array.isArray(spec.bytes) && spec.bytes.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)) {
      if (spec.bytes.length > 16 * 1024 * 1024) {
        throw new Error(`${sourceLabel(step)}: test file exceeds the 16 MiB harness limit`);
      }
      bytes = Buffer.from(spec.bytes);
    } else {
      throw new Error(`${sourceLabel(step)}: test file bytes must be a String or byte Array`);
    }
    if (bytes.length > 16 * 1024 * 1024) throw new Error(`${sourceLabel(step)}: test file exceeds the 16 MiB harness limit`);
    const delay = spec.delay_ms === undefined ? 0 : Number(spec.delay_ms);
    if (!Number.isInteger(delay) || delay < 0 || delay > 1000) {
      throw new Error(`${sourceLabel(step)}: test file delay_ms must be between 0 and 1000`);
    }
    if (spec.fail_read !== undefined && typeof spec.fail_read !== "boolean") {
      throw new Error(`${sourceLabel(step)}: test file fail_read must be true or false`);
    }
    return {
      name: typeof spec.name === "string" && spec.name.length > 0 ? spec.name : defaultName || "mochi-test.bin",
      type: typeof spec.type === "string" ? spec.type : "",
      lastModified: Number.isFinite(Number(spec.last_modified)) ? Number(spec.last_modified) : 0,
      bytes: bytes,
      delayMs: delay,
      failRead: spec.fail_read === true,
    };
  });
}

async function dispatchFileDrop(page, tag, selector, files) {
  return page.evaluate(({ tag, selector, files }) => {
    const host = document.querySelector(tag);
    const target = host && host.shadowRoot && host.shadowRoot.querySelector(selector);
    if (!target) throw new Error(`selector '${selector}' matched no drop target`);
    const transfer = new DataTransfer();
    files.forEach((spec) => {
      const binary = atob(spec.bytesBase64);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
      const file = new File([bytes], spec.name, { type: spec.type, lastModified: spec.lastModified });
      if (spec.delayMs > 0 || spec.failRead) {
        const originalSlice = file.slice.bind(file);
        Object.defineProperty(file, "slice", {
          value(start, end) {
            const part = originalSlice(start, end);
            return {
              stream() {
                const source = part.stream().getReader();
                let failed = false;
                return new ReadableStream({
                  async pull(controller) {
                    if (spec.failRead && !failed) {
                      failed = true;
                      controller.error(new Error("synthetic file read failure"));
                      return;
                    }
                    const result = await source.read();
                    if (!result.done && spec.delayMs > 0) {
                      await new Promise((resolve) => setTimeout(resolve, spec.delayMs));
                    }
                    if (result.done) controller.close();
                    else controller.enqueue(result.value);
                  },
                  cancel(reason) { return source.cancel(reason); },
                }, { highWaterMark: 0 });
              },
            };
          },
        });
      }
      transfer.items.add(file);
    });
    const dragover = new DragEvent("dragover", {
      bubbles: true, cancelable: true, composed: true, dataTransfer: transfer,
    });
    target.dispatchEvent(dragover);
    target.dispatchEvent(new DragEvent("drop", {
      bubbles: true, cancelable: true, composed: true, dataTransfer: transfer,
    }));
    return dragover.defaultPrevented;
  }, {
    tag,
    selector,
    files: files.map((file) => ({
      name: file.name, type: file.type, lastModified: file.lastModified,
      bytesBase64: file.bytes.toString("base64"), delayMs: file.delayMs, failRead: file.failRead,
    })),
  });
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

// Keep all three browser diagnostic channels and consume them at each step.
// Console Error arguments need explicit serialization: Firefox text() omits
// their message. Promise entries preserve order without unhandled rejections.
function collectDiagnostics(page) {
  const pending = [];
  page.on("pageerror", error => pending.push(Promise.resolve({ kind: "browser", message: error.message })));
  page.on("console", entry => {
    if (entry.type() !== "error") return;
    pending.push(Promise.all(entry.args().map(argument =>
      argument.evaluate(value => value instanceof Error ? value.message : "")))
      .then(details => ({ kind: "console", message: [entry.text(), ...details.filter(Boolean)].join(" ") }))
      .catch(error => ({ kind: "console", message: `${entry.text()} (cannot read console arguments: ${error.message})` })));
  });
  return async () => {
    const runtime = await page.evaluate(() => (window.__mochiTestErrors || []).splice(0));
    const diagnostics = await Promise.all(pending.splice(0));
    return diagnostics.concat(runtime.map(error => ({
      kind: "Mochi runtime", message: error.message || JSON.stringify(error), source: error.source,
    })));
  };
}

function assertDiagnostics(diagnostics, origin, expected = null, actionError = null) {
  const unexpected = diagnostics.filter(error => expected === null || !error.message.includes(expected));
  if (unexpected.length) {
    throw new Error(`${origin}: ${unexpected.map(error =>
      `${error.kind} error${error.source ? ` (${error.source})` : ""}: ${error.message}`).join("\n")}`);
  }
  // A driver/assertion failure cannot satisfy expect_error by itself. A
  // rejected mount is allowed only alongside its matching browser diagnostic.
  if (actionError && !(expected !== null && diagnostics.length && actionError.message.includes(expected))) {
    if (actionError.message.startsWith(`${origin}:`)) throw actionError;
    throw new Error(`${origin}: ${actionError.message}`);
  }
  if (expected !== null && diagnostics.length === 0) {
    throw new Error(`${origin}: expected browser error containing '${expected}', but no error occurred`);
  }
}

async function readyComponent(page, tag) {
  await page.waitForFunction(tag => !!document.querySelector(tag)?._mochiReady, tag, { timeout: 5000 });
  await page.evaluate(async tag => { await document.querySelector(tag)._mochiReady; }, tag);
}

async function settleFrames(page) {
  await page.evaluate(() => new Promise(resolve => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  }));
}

async function runCase(browser, browserName, baseUrl, testCase) {
  let page;
  let origin = sourceLabel(testCase.ruby_file ? testCase : testCase.steps[0] || { ruby_file: "<ruby test>", line: 1 });
  try {
    page = await browser.newPage();
    const drainDiagnostics = collectDiagnostics(page);
    await page.addInitScript(() => {
      window.__mochiTestErrors = [];
      window.__mochiTestPointer = null;
      window.__mochiTestLostCaptures = [];
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
      document.addEventListener("lostpointercapture", (event) => {
        window.__mochiTestLostCaptures.push(event.pointerId);
      }, true);
    });

    let host = null;
    let detachedHost = null;
    let expectedError = null;
    let activePointer = null;
    let expectationOrigin = null;
    await page.goto(`${baseUrl}/`);
    await page.waitForFunction(() => window.MochiLoader && window.MochiLoader.manifest);
    assertDiagnostics(await drainDiagnostics(), origin);

    for (const step of testCase.steps) {
      origin = sourceLabel(step);
      if (step.operation === "expect_error") {
        assertDiagnostics(await drainDiagnostics(), origin);
        if (expectedError !== null) throw new Error(`${expectationOrigin}: expect_error must be followed by an action`);
        if (typeof step.message !== "string" || !step.message.trim()) {
          throw new Error(`${origin}: expect_error requires a non-empty message`);
        }
        expectedError = step.message;
        expectationOrigin = origin;
        continue;
      }
      let actionError = null;
      try {
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
          await readyComponent(page, host);
          await settleFrames(page);
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
            const pointerId = activePointer.id;
            await page.mouse.up();
            activePointer = null;
            await waitForPointerIdle(page);
            const observed = await page.evaluate((id) => window.__mochiTestLostCaptures.includes(id), pointerId);
            if (!observed) throw new Error(`${origin}: browser did not deliver lostpointercapture`);
          } else {
            const captured = await page.evaluate(() => {
              const pointer = window.__mochiTestPointer;
              return !!(pointer && pointer.target && pointer.target.hasPointerCapture &&
                pointer.target.hasPointerCapture(pointer.id));
            });
            if (captured) throw new Error(`${origin}: pointer capture remained active`);
          }
        } else if (step.operation === "press") {
          if (!host) throw new Error(`${origin}: mount a component before using press`);
          await page.keyboard.press(step.key);
        } else if (["click", "fill", "focus", "assert_focused", "assert_text", "assert_attribute", "assert_no_attribute", "assert_value"].includes(step.operation)) {
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
            if (step.operation === "focus" || step.operation === "assert_focused") {
              if (step.operation === "focus") target.focus();
              let active = document.activeElement;
              while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
              return { focused: active === target };
            }
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
          if (["focus", "assert_focused"].includes(step.operation) && !result.focused) {
            throw new Error(`${origin}: expected focus at '${step.selector}'`);
          }
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
        } else if (step.operation === "select_files") {
          if (!host) throw new Error(`${origin}: mount a component before selecting files`);
          const files = syntheticFiles(step);
          const target = page.locator(host).locator(step.selector);
          await target.setInputFiles(files.map((file) => ({
            name: file.name,
            mimeType: file.type,
            lastModified: file.lastModified,
            buffer: file.bytes,
          })));
        } else if (step.operation === "drop_files") {
          if (!host) throw new Error(`${origin}: mount a component before dropping files`);
          const files = syntheticFiles(step);
          const accepted = await dispatchFileDrop(page, host, step.selector, files);
          if (!accepted) throw new Error(`${origin}: Mochi did not accept the synthetic file dragover`);
        } else if (step.operation === "drag") {
          if (!host) throw new Error(`${origin}: mount a component before dragging`);
          await page.locator(host).locator(step.source).dragTo(page.locator(host).locator(step.target));
        } else if (step.operation === "assert_state") {
          if (!host) throw new Error(`${origin}: mount a component before asserting state`);
          const actual = await page.locator(host).locator(step.selector).innerText();
          if (actual.trim() !== step.expected) {
            throw new Error(`${origin}: expected state '${step.expected}', got '${actual.trim()}'`);
          }
        } else if (step.operation === "wait") {
          await page.waitForFunction(() => {
            const stats = window.MochiLoader.debugStats();
            if (stats.pendingFetches || stats.activeFetches || stats.pendingHostRequests || stats.pendingPointerMoves) return false;
            const roots = [document];
            while (roots.length) {
              for (const element of roots.pop().querySelectorAll("*")) {
                if (element._mochiMountState === "mounting") return false;
                if (element.shadowRoot) roots.push(element.shadowRoot);
              }
            }
            return true;
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
            await readyComponent(page, host);
            await settleFrames(page);
          }
        } else {
          throw new Error(`${origin}: unsupported Ruby test operation '${step.operation}'`);
        }
      } catch (error) {
        actionError = error;
      }
      assertDiagnostics(await drainDiagnostics(), origin, expectedError, actionError);
      expectedError = null;
      expectationOrigin = null;
    }
    if (expectedError !== null) throw new Error(`${expectationOrigin}: expect_error must be followed by an action`);
    await settleFrames(page);
    assertDiagnostics(await drainDiagnostics(), origin);
    console.log(`PASS [${browserName}] ${testCase.name}`);
    return true;
  } catch (error) {
    if (error.message.startsWith(`${origin}:`)) throw error;
    throw new Error(`${origin}: ${error.message}`);
  } finally {
    if (page) await page.close();
  }
}

async function main() {
  const [bundleDir, planPath, browserList = "chromium,firefox,webkit"] = process.argv.slice(2);
  if (!bundleDir || !planPath) {
    console.error("usage: mochi_test_runner.cjs <bundle-dir> <test-plan.json> [browsers]");
    process.exitCode = 2;
    return;
  }
  const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
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

  let failed = false;
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
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
    if (server.listening) await new Promise((resolve) => server.close(resolve));
  }
  if (failed) process.exitCode = 1;
}

module.exports = { syntheticFiles, collectDiagnostics, assertDiagnostics, runCase };

if (require.main === module && process.env.MOCHI_TEST_RUNNER_LIBRARY !== "1") {
  main().catch((error) => {
    console.error(error.stack || error);
    process.exitCode = 1;
  });
}
