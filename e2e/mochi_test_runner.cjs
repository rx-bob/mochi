const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");

const [bundleDir, planPath] = process.argv.slice(2);
if (!bundleDir || !planPath) {
  console.error("usage: mochi_test_runner.cjs <bundle-dir> <test-plan.json>");
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

async function runCase(browser, baseUrl, testCase) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.__mochiTestErrors = [];
    document.addEventListener("mochi:error", (event) => {
      window.__mochiTestErrors.push(event.detail || { message: "Mochi runtime error" });
    });
  });

  let host = null;
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
      } else if (step.operation === "click" || step.operation === "fill" ||
                 step.operation === "assert_text") {
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
          const actual = (target.innerText || target.textContent || "").trim();
          return { actual };
        }, { tag: host, step });

        if (result.missing) throw new Error(`${origin}: selector '${step.selector}' matched no visible element`);
        if (result.invalid) throw new Error(`${origin}: ${result.invalid}`);
        if (step.operation === "assert_text" && result.actual !== step.expected) {
          throw new Error(`${origin}: expected '${step.expected}' at '${step.selector}', got '${result.actual}'`);
        }
      } else if (step.operation === "wait") {
        await page.waitForFunction(() => {
          const stats = window.MochiLoader.debugStats();
          return stats.pendingFetches === 0 && stats.activeFetches === 0 &&
            stats.pendingHostRequests === 0;
        }, null, { timeout: 5000 });
        await page.evaluate(() => new Promise((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(resolve));
        }));
      } else {
        throw new Error(`${origin}: unsupported Ruby test operation '${step.operation}'`);
      }

      const runtimeErrors = await page.evaluate(() => window.__mochiTestErrors || []);
      if (runtimeErrors.length > 0) {
        const error = runtimeErrors[0];
        const where = error.source ? ` (${error.source})` : "";
        throw new Error(`${origin}: Mochi runtime error${where}: ${error.message || JSON.stringify(error)}`);
      }
      if (errors.length > 0) throw new Error(`${origin}: browser error: ${errors[0]}`);
    }
    console.log(`PASS ${testCase.name}`);
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
  let browser;
  let failed = false;
  try {
    const launchOptions = { headless: true };
    if (process.env.MOCHI_TEST_CHANNEL) launchOptions.channel = process.env.MOCHI_TEST_CHANNEL;
    browser = await chromium.launch(launchOptions);
    const baseUrl = `http://127.0.0.1:${address.port}`;
    for (const testCase of plan.tests || []) {
      try {
        await runCase(browser, baseUrl, testCase);
      } catch (error) {
        failed = true;
        console.error(`FAIL ${testCase.name}: ${error.message}`);
      }
    }
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
  if (failed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
