import { expect, test, type Browser } from "@playwright/test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runRubyProject, withCompiledProject } from "./framework_helpers";

const { runCase } = require("../mochi_test_runner.cjs");
const fixture = path.join(__dirname, "../fixtures/clay_storage");

test("portable storage runs the same Ruby receipt scenario as desktop", ({ browserName }) => {
  expect(runRubyProject(fixture, browserName, "storage_test.rb"))
    .toContain(`PASS [${browserName}] confirms storage writes and distinguishes absence from empty text`);
});

test("portable storage rolls back quota failure with the same Ruby scenario as desktop", async ({ browser, browserName }) => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-storage-probe-"));
  try {
    const plan = path.join(work, "plan.json");
    execFileSync("ruby", [path.join(__dirname, "../../runtime/test/mochi_test_recorder.rb"),
      path.join(fixture, "probes"), plan, "storage_quota_test.rb"]);
    const [scenario] = JSON.parse(fs.readFileSync(plan, "utf8")).tests;
    const wrappedBrowser = {
      newPage: async () => {
        const page = await browser.newPage();
        await page.addInitScript(() => {
          const set = Storage.prototype.setItem;
          Storage.prototype.setItem = function (key, value) {
            if (key === "station-label" && value.length === 5000)
              throw new DOMException("quota", "QuotaExceededError");
            return set.call(this, key, value);
          };
        });
        return page;
      },
    };
    await withCompiledProject(fixture, async url => {
      await runCase(wrappedBrowser as Browser, browserName, url, scenario);
    }, "");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});
