import { test, expect, type Page, type TestInfo } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withCompiledProject, runRubyProject } from "./framework_helpers";

const repoRoot = path.resolve(__dirname, "../..");
const compiler = path.join(repoRoot, "compiler/mochi");
const fixture = path.join(__dirname, "../fixtures/ui_contracts");

test("inspector renders exactly 12 of 48 records without browser errors @ui-inspector", async ({ page }, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await page.addInitScript(() => {
    (window as any).__uiErrors = [];
    document.addEventListener("mochi:error", event => (window as any).__uiErrors.push((event as CustomEvent).detail));
  });
  await withCompiledProject(fixture, async (baseURL, bundle) => {
    await attachArtifacts(testInfo, fixture, bundle);
    await page.goto(baseURL);
    await expect(page.locator("inspector-root .record")).toHaveCount(12);
    await expect(page.locator("inspector-root .total")).toHaveText("48");
    await expect(page.locator("inspector-root .record").first()).toHaveAttribute("data-id", "record-1");
    await expect(page.locator("inspector-root .record").last()).toHaveAttribute("data-id", "record-12");
    expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
    expect(errors).toEqual([]);
  });
});

// Discover every authored Ruby suite. Graph/form stories add their files to
// this same project; these entry points then include them without new harnesses.
const rubySuites: Record<string, string> = {
  "inspector_test.rb": "@ui-inspector",
  "editable_graph_test.rb": "@ui-graph",
  "nested_form_test.rb": "@ui-form",
};
for (const file of fs.readdirSync(path.join(fixture, "test"), { recursive: true }).map(String).sort()
  .filter(file => file.endsWith("_test.rb"))) {
  test(`Ruby-authored UI scenarios: ${file} ${rubySuites[file] || "@ui"}`, async ({ browserName }) => {
    test.setTimeout(240_000);
    const output = runRubyProject(fixture, browserName, file);
    expect(output).toContain(`PASS [${browserName}]`);
  });
}

function probeTarget(name: string): string {
  if (/^(01|05|07|11)-/.test(name)) return "@ui-form";
  if (/^06-/.test(name) || name === "09-wheel") return "@ui-graph";
  return "@ui-inspector";
}

// These are evidence assertions, not acceptance claims for the owning stories.
// A repaired defect must replace its observed-failure assertion with the Ruby
// oracle in UI_FIXTURE_CONTRACTS.md; never skip the reproducer.
const compileFailures: Record<string, { message: string; owner: string }> = {
  "01-if-in-each": { message: `invalid Ruby expression "if row['visible']" in each`, owner: "E2.S1" },
  "05-attribute-quotes": { message: 'unclosed template placeholder near "{@modal["', owner: "E2.S2" },
  "05-conditional-quotes": { message: "stray '}' in template", owner: "E2.S2" },
  "10-redo": { message: 'unsupported redo in template expression "redo"', owner: "intentional Ruby keyword; E1.S3" },
  "12-root-css": { message: 'CSS import "../../styles/base.css"', owner: "E7.S2" },
  "12-missing-css": { message: 'CSS import "missing.css"', owner: "intentional missing-file error; E7.S2" },
};
const mountFailures: Record<string, { message: string; owner: string }> = {
  "02-slice": { message: "ProbeRoot#slice: unknown method", owner: "E1.S2" },
  "03-constant": { message: "ProbeRoot#initialize: bad opcode", owner: "E1.S3" },
  "09-json": { message: "ProbeRoot#initialize: unknown class", owner: "E6.S1" },
  "09-time": { message: "ProbeRoot#initialize: unknown class", owner: "E6.S2" },
  "09-math": { message: "ProbeRoot#initialize: unknown class", owner: "deferred Math" },
  "09-regexp": { message: "ProbeRoot#initialize: unknown class", owner: "deferred Regexp" },
};
const textProbes: Record<string, { selector: string; text: string; count?: number; owner: string }> = {
  "01-each-in-if": { selector: "div", text: "Alpha", owner: "E2.S1" },
  "01-nested-each": { selector: "section p", text: "Alpha", owner: "E2.S1" },
  "02-brackets": { selector: "output", text: "2", owner: "E1.S2; Ruby oracle is [2, 3]" },
  "03-singleton": { selector: "output", text: "1794571200000", owner: "E1.S3" },
  "04-structured-records": { selector: "output", text: "480", owner: "E4.S1–E4.S3" },
  "04-concatenation": { selector: "output", text: "24370", owner: "E4.S1–E4.S3" },
  "04-repeated-split": { selector: "output", text: "480", count: 20, owner: "E4.S1–E4.S3" },
  "10-next": { selector: "output", text: "alpha,beta", owner: "E1.S3" },
  "11-boolean": { selector: "output", text: "false", owner: "E2.S4" },
};

function sha256(file: string): string {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

async function attachArtifacts(testInfo: TestInfo, source: string, bundle?: string) {
  const hashes = (directory: string) => Object.fromEntries(
    fs.readdirSync(directory, { recursive: true }).map(String).sort()
      .filter(file => fs.statSync(path.join(directory, file)).isFile())
      .map(file => [file, sha256(path.join(directory, file))]));
  await testInfo.attach("artifact-identity", {
    body: JSON.stringify({ compiler: sha256(compiler), source: hashes(source),
      bundle: bundle ? hashes(bundle) : null,
      manifest: bundle ? JSON.parse(fs.readFileSync(path.join(bundle, "mochi-manifest.json"), "utf8")) : null }, null, 2),
    contentType: "application/json",
  });
}

async function captureErrors(page: Page) {
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];
  const consoleDetails: Promise<void>[] = [];
  page.on("console", message => {
    if (message.type() !== "error") return;
    const index = consoleErrors.push(message.text()) - 1;
    // Firefox's text() prints only "Error" for console Error objects. Read
    // their messages so negative probes still reject unrelated diagnostics.
    consoleDetails.push(Promise.all(message.args().map(argument =>
      argument.evaluate(value => value instanceof Error ? value.message : "")))
      .then(details => { consoleErrors[index] += details.filter(Boolean).join(" "); }));
  });
  page.on("pageerror", error => pageErrors.push(error.message));
  await page.addInitScript(() => {
    (window as any).__uiErrors = [];
    document.addEventListener("mochi:error", event => (window as any).__uiErrors.push((event as CustomEvent).detail));
  });
  return { consoleErrors, pageErrors, settleConsole: () => Promise.all(consoleDetails) };
}

for (const [name, failure] of Object.entries(compileFailures)) {
  test(`feedback evidence ${name}: compiler diagnostic ${probeTarget(name)}`, async ({}, testInfo) => {
    testInfo.annotations.push({ type: "owner", description: failure.owner });
    const source = path.join(fixture, "probes", name);
    await attachArtifacts(testInfo, source);
    let diagnostic = "";
    try {
      await withCompiledProject(source, async () => {}, "<probe-root></probe-root>");
    } catch (error: any) {
      expect(error.status).toBe(1);
      diagnostic = error.stderr.toString();
    }
    expect(diagnostic).toContain(failure.message);
    expect(diagnostic).toMatch(/lib\/(?:nested\/)?ProbeRoot\.rb:\d+/);
    if (name.startsWith("12-")) expect(diagnostic).toContain("was not found");
    await testInfo.attach("compiler-diagnostic", { body: diagnostic, contentType: "text/plain" });
  });
}

const runtimeProbes = [...Object.keys(mountFailures), ...Object.keys(textProbes),
  "06-svg-each", "07-binding-handler", "08-event-dataset", "09-wheel", "12-assets-css"];
for (const name of runtimeProbes) {
  test(`feedback evidence ${name}: runtime observation ${probeTarget(name)}`, async ({ page, browserName }, testInfo) => {
    const failure = mountFailures[name];
    const textProbe = textProbes[name];
    testInfo.annotations.push({ type: "owner", description: failure?.owner || textProbe?.owner ||
      ({ "06-svg-each": "E3.S1", "07-binding-handler": "E2.S3", "08-event-dataset": "E3.S2",
         "09-wheel": "E5.S2", "12-assets-css": "E7.S2" } as Record<string, string>)[name] });
    const { consoleErrors, pageErrors, settleConsole } = await captureErrors(page);
    const source = path.join(fixture, "probes", name);
    await withCompiledProject(source, async (baseURL, bundle) => {
      await attachArtifacts(testInfo, source, bundle);
      await page.goto(baseURL);
      await page.waitForFunction(() => !!(document.querySelector("probe-root") as any)?._mochiReady);
      const mountError = await page.evaluate(async () => {
        try { await (document.querySelector("probe-root") as any)._mochiReady; return null; }
        catch (error: any) { return error.message; }
      });
      if (failure) {
        expect(mountError).toContain(failure.message);
        expect(mountError).toMatch(/lib\/ProbeRoot\.rb:\d+/);
        const runtimeErrors = await page.evaluate(() => (window as any).__uiErrors);
        expect(runtimeErrors).toHaveLength(1);
        expect(runtimeErrors[0].message).toContain(failure.message);
        await settleConsole();
        for (const message of [...consoleErrors, ...pageErrors]) expect(message).toContain(failure.message);
        await testInfo.attach("mount-diagnostic", {
          body: JSON.stringify({ mountError, runtimeErrors, consoleErrors, pageErrors }, null, 2), contentType: "application/json",
        });
        return;
      }
      expect(mountError).toBeNull();
      const root = page.locator("probe-root");
      if (textProbe) {
        const nodes = root.locator(textProbe.selector);
        await expect(nodes).toHaveText(Array(textProbe.count || 1).fill(textProbe.text));
      } else if (name === "06-svg-each") {
        const paths = root.locator("path");
        await expect(paths).toHaveCount(2);
        await expect(paths.nth(0)).toHaveAttribute("d", "M 0 0 L 20 20");
        await expect(paths.nth(1)).toHaveAttribute("d", "M 20 20 L 40 0");
        expect(await paths.evaluateAll(nodes => nodes.map(node => node.namespaceURI)))
          .toEqual(["http://www.w3.org/2000/svg", "http://www.w3.org/2000/svg"]);
        // Chromium reports transient invalid placeholders; other engines can be silent.
        if (browserName === "chromium") expect(consoleErrors).toHaveLength(2);
        for (const message of consoleErrors) expect(message).toMatch(/(?:<path> attribute d: Expected moveto|Problem parsing d=)/);
      } else if (name === "07-binding-handler") {
        await root.locator("input").fill("needle");
        await expect(root.locator("input")).toHaveValue("needle");
        await expect(root.locator(".query")).toHaveText(""); // E2.S3 oracle: needle
        await expect(root.locator(".seen")).toHaveText(":a"); // E2.S3 oracle: needle:a
        await root.locator("select").selectOption("b");
        await expect(root.locator(".project")).toHaveText("b");
        await expect(root.locator(".seen")).toHaveText(":b");
      } else if (name === "08-event-dataset") {
        await root.locator("span").click();
        await expect(root.locator(".selected")).toHaveText(""); // target is span, intentionally empty
        await expect(root.locator(".current")).toHaveText(""); // E3.S2 must expose handler data
        await root.locator("tr").dispatchEvent("click");
        await expect(root.locator(".selected")).toHaveText("log-001");
      } else if (name === "09-wheel") {
        await root.locator("div").dispatchEvent("wheel", { deltaX: 4, deltaY: 12 });
        await expect(root.locator("output")).toHaveText(":"); // E5.S2 oracle: 4:12
      } else if (name === "12-assets-css") {
        await expect(root.locator(".shared")).toHaveCSS("color", "rgb(12, 34, 56)");
        await expect(root.locator("img")).toHaveJSProperty("naturalWidth", 1);
        await expect(root.locator("use")).toHaveAttribute("href", `${baseURL}/mochi-icons/home.svg#mochi-icon`);
        expect(fs.existsSync(path.join(bundle, "public/probe.svg"))).toBe(true);
        expect(fs.existsSync(path.join(bundle, "probe.svg"))).toBe(false);
        expect(fs.existsSync(path.join(bundle, "mochi-icons/home.svg"))).toBe(true);
        expect(fs.existsSync(path.join(bundle, "mochi-icons/unused.svg"))).toBe(false);
      }
      expect(await page.evaluate(() => (window as any).__uiErrors)).toEqual([]);
      await settleConsole();
      expect(pageErrors).toEqual([]);
      if (name !== "06-svg-each") expect(consoleErrors).toEqual([]);
      await testInfo.attach("browser-console", { body: JSON.stringify(consoleErrors), contentType: "application/json" });
    }, "<probe-root></probe-root>");
  });
}

test("feedback evidence 11-boolean: typecheck rejects documented Boolean prop @ui-form", async ({}, testInfo) => {
  testInfo.annotations.push({ type: "owner", description: "E2.S4" });
  const source = path.join(fixture, "probes/11-boolean");
  await attachArtifacts(testInfo, source);
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-ui-typecheck-"));
  try {
    fs.cpSync(source, project, { recursive: true });
    let diagnostic = "";
    try {
      execFileSync(compiler, ["--typecheck", "-i", project, "-o", path.join(project, "bundle")], { stdio: "pipe" });
    } catch (error: any) {
      expect(error.status).toBe(1);
      diagnostic = error.stdout.toString();
      expect(error.stderr.toString()).toContain("Sorbet typecheck failed");
    }
    const errors = diagnostic.split("\n").filter(line => line.includes("[Error #"));
    expect(errors.length).toBeGreaterThan(0);
    for (const error of errors) {
      expect(error).toContain("Unable to resolve constant `Boolean`");
      expect(error).toMatch(/lib\/ProbeRoot\.rb@\d+:\d+/);
    }
    await testInfo.attach("typecheck-diagnostic", { body: diagnostic, contentType: "text/plain" });
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
