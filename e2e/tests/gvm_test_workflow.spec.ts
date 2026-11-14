import { test, expect, type Browser, type Page, type TestInfo } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";

const { runCase } = require("../mochi_test_runner.cjs");
const fixture = path.resolve(__dirname, "../fixtures/ui_contracts");
const repoRoot = path.resolve(__dirname, "../..");

function recordCase(testInfo: TestInfo, steps: string[]) {
  const directory = testInfo.outputPath("ruby");
  fs.mkdirSync(directory, { recursive: true });
  const source = path.join(directory, "runner_test.rb");
  fs.writeFileSync(source, ['Mochi::Test.test("runner diagnostics") do', ...steps.map(step => `  ${step}`), "end"].join("\n"));
  const plan = path.join(directory, "plan.json");
  execFileSync("ruby", [path.join(repoRoot, "runtime/test/mochi_test_recorder.rb"), directory, plan]);
  return JSON.parse(fs.readFileSync(plan, "utf8")).tests[0];
}

async function diagnosticBrowser(browser: Browser, mode: string) {
  let page: Page;
  return {
    driver: { newPage: async () => {
      page = await browser.newPage();
      await page.addInitScript(mode => {
        if (mode === "startup") document.addEventListener("DOMContentLoaded", () => console.error("controlled startup error"));
        if (mode === "mount") {
          const observer = new MutationObserver(() => {
            if (document.querySelector("inspector-root")) {
              observer.disconnect();
              console.error("controlled mount error");
            }
          });
          observer.observe(document, { childList: true, subtree: true });
        }
        if (["click", "mixed", "exception"].includes(mode)) {
          document.addEventListener("click", () => {
            if (mode === "exception") throw new Error("controlled page exception");
            console.error(new Error("controlled click error"));
            document.dispatchEvent(new CustomEvent("mochi:error", {
              detail: { message: "controlled click error", source: "lib/InspectorRoot.rb:1" },
            }));
            if (mode === "mixed") console.error("unrelated click error");
          }, { once: true });
        }
      }, mode);
      return page;
    } },
    closed: () => page.isClosed(),
  };
}

for (const [mode, line, message] of [
  ["startup", 1, "controlled startup error"],
  ["mount", 2, "controlled mount error"],
  ["click", 3, "controlled click error"],
  ["exception", 3, "controlled page exception"],
] as const) {
  test(`Ruby runner rejects ${mode} errors at the authored source line`, async ({ browser, browserName }, testInfo) => {
    const scenario = recordCase(testInfo, ['mount "inspector-root"', 'click ".next"']);
    const observed = await diagnosticBrowser(browser, mode);
    await withCompiledProject(fixture, async baseURL => {
      await expect(runCase(observed.driver, browserName, baseURL, scenario))
        .rejects.toThrow(new RegExp(`runner_test\\.rb:${line}:.*${message}`));
      expect(observed.closed()).toBe(true);
    }, "");
  });
}

test("Ruby runner consumes a matching error then permits later valid interactions", async ({ browser, browserName }, testInfo) => {
  const scenario = recordCase(testInfo, [
    'mount "inspector-root"', 'expect_error "controlled click error"', 'click ".next"',
    'assert_text ".page", "2"', 'click ".next"', 'assert_text ".page", "3"',
  ]);
  const observed = await diagnosticBrowser(browser, "click");
  await withCompiledProject(fixture, async baseURL => {
    expect(await runCase(observed.driver, browserName, baseURL, scenario)).toBe(true);
    expect(observed.closed()).toBe(true);
  }, "");
});

test("Ruby runner matches a rejected mount and consumes all diagnostic channels", async ({ browser, browserName }, testInfo) => {
  const scenario = recordCase(testInfo, [
    'expect_error "ProbeRoot#missing_mount_method: unknown method"', 'mount "probe-root"', 'unmount',
  ]);
  await withCompiledProject(path.join(fixture, "probes/runner-mount-error"), async baseURL => {
    expect(await runCase(browser, browserName, baseURL, scenario)).toBe(true);
  }, "");
});

test("Ruby wait_for_settled waits for a lazily mounted child descriptor", async ({ browser, browserName }, testInfo) => {
  const scenario = recordCase(testInfo, [
    'mount "nested-form-root", open: false', 'click ".toggle"', 'wait_for_settled',
    'assert_value "[data-field=\'a\'] field-editor >>> .draft", "Alpha"',
  ]);
  let delayed = false;
  const driver = { newPage: async () => {
    const page = await browser.newPage();
    await page.route("**/components/field-editor.json", async route => {
      delayed = true;
      await new Promise(resolve => setTimeout(resolve, 300));
      await route.continue();
    });
    return page;
  } };
  await withCompiledProject(fixture, async baseURL => {
    expect(await runCase(driver, browserName, baseURL, scenario)).toBe(true);
    expect(delayed).toBe(true);
  }, "");
});

for (const [name, steps, mode, message] of [
  ["mixed", ['mount "inspector-root"', 'expect_error "controlled click error"', 'click ".next"'], "mixed", "unrelated click error"],
  ["missing", ['mount "inspector-root"', 'expect_error "absent error"', 'click ".next"'], "none", "but no error occurred"],
  ["dangling", ['mount "inspector-root"', 'expect_error "absent error"'], "none", "expect_error must be followed by an action"],
  ["replaced", ['mount "inspector-root"', 'expect_error "first"', 'expect_error "second"'], "none", "expect_error must be followed by an action"],
  ["driver", ['mount "inspector-root"', 'pointer_move_by 2, 3'], "none", "pointer_move_by requires pointer_press"],
] as const) {
  test(`Ruby runner rejects ${name} negative scenario and closes its page`, async ({ browser, browserName }, testInfo) => {
    const scenario = recordCase(testInfo, [...steps]);
    const observed = await diagnosticBrowser(browser, mode);
    await withCompiledProject(fixture, async baseURL => {
      await expect(runCase(observed.driver, browserName, baseURL, scenario)).rejects.toThrow(message);
      expect(observed.closed()).toBe(true);
    }, "");
  });
}

test("shared compiler helper removes temporary output after compilation fails", async () => {
  let project = "";
  try {
    await withCompiledProject(path.join(fixture, "probes/runner-compile-error"), async () => {
      throw new Error("compilation unexpectedly succeeded");
    }, "<probe-root></probe-root>");
  } catch (error: any) {
    expect(error.stderr.toString()).toContain("invalid Ruby expression");
    project = error.stdout.toString().match(/input_dir:([^,\n]+)/)[1];
  }
  expect(project).not.toBe("");
  expect(fs.existsSync(project)).toBe(false);
});

test("shared compiler helper closes server and removes output after browser assertion fails", async ({ page }) => {
  let project = "";
  let baseURL = "";
  await expect(withCompiledProject(fixture, async (url, bundle) => {
    project = path.dirname(bundle);
    baseURL = url;
    await page.goto(url);
    await expect(page.locator("inspector-root .record")).toHaveCount(12);
    expect(await page.locator("inspector-root .record").count()).toBe(13);
  })).rejects.toThrow("13");
  expect(project).not.toBe("");
  expect(fs.existsSync(project)).toBe(false);
  await expect(fetch(baseURL)).rejects.toThrow();
});

for (const failure of ["compile", "assertion"] as const) {
  test(`mochi test removes its workspace after ${failure} failure`, async ({ browserName }, testInfo) => {
    const project = testInfo.outputPath("project");
    const source = failure === "compile" ? path.join(fixture, "probes/runner-compile-error") : fixture;
    fs.cpSync(source, project, { recursive: true });
    fs.mkdirSync(path.join(project, "test"), { recursive: true });
    const tag = failure === "compile" ? "probe-root" : "inspector-root";
    fs.writeFileSync(path.join(project, "test/failure_test.rb"),
      `Mochi::Test.test("controlled failure") do\n  mount "${tag}"\n  assert_text ".total", "wrong"\nend\n`);
    let workspace = "";
    try {
      runRubyProject(project, browserName, "failure_test.rb");
    } catch (error: any) {
      expect(error.message).toContain(failure === "compile" ? "invalid Ruby expression" : "failure_test.rb:3");
      workspace = error.message.match(/Working Dir: ([^\n]+)/)[1];
    }
    expect(workspace).not.toBe("");
    expect(fs.existsSync(workspace)).toBe(false);
    expect(fs.existsSync(path.join(project, "bundle"))).toBe(false);
  });
}

test("Ruby capture assertion observes the bound ancestor before gotpointercapture", async ({ browser, browserName }, testInfo) => {
  const scenario = recordCase(testInfo, [
    'mount "editable-graph-root"',
    'pointer_press "[data-node=\'b\'] circle"',
    'assert_pointer_capture_released',
  ]);
  const observed = await diagnosticBrowser(browser, "none");
  await withCompiledProject(fixture, async baseURL => {
    await expect(runCase(observed.driver, browserName, baseURL, scenario)).rejects.toThrow("pointer capture remained active");
    expect(observed.closed()).toBe(true);
  }, "");
});
