import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";
import { setupConsoleLogging } from "./test_utils";

test.use({ channel: "chrome" });
test.describe.configure({ mode: "serial" });

const repoRoot = path.resolve(__dirname, "..", "..");
const compilerBinary = path.join(repoRoot, "compiler", "mochi");

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
};

function startStaticServer(rootDir: string): Promise<{ server: http.Server; baseURL: string }> {
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
    if (requestPath === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    const relative = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
    const filePath = path.resolve(rootDir, relative);
    if (filePath !== rootDir && !filePath.startsWith(rootDir + path.sep)) {
      response.writeHead(403);
      response.end();
      return;
    }
    fs.readFile(filePath, (error, data) => {
      if (error) {
        response.writeHead(404);
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": CONTENT_TYPES[path.extname(filePath)] || "application/octet-stream",
      });
      response.end(data);
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("server did not bind a port");
      resolve({ server, baseURL: `http://127.0.0.1:${address.port}` });
    });
  });
}

const rowScreenSource = `
class RowScreen
  @tag_name = "row-screen"
  @days
  @models
  @rows
  @visible_rows
  @compact_rows
  @detail_rows
  @period
  @total
  @last_line

  def initialize
    @days = [
      "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15",
      "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20",
      "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25",
      "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30",
      "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04",
      "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09"
    ]
    @models = [
      {"name" => "claude-sonnet", "share" => 20},
      {"name" => "gemini-pro", "share" => 15},
      {"name" => "gpt-6-astra", "share" => 25},
      {"name" => "gpt-6-sol", "share" => 15},
      {"name" => "qwen-coder", "share" => 15},
      {"name" => "gpt-oss", "share" => 10}
    ]
    @period = 30
    rebuild
  end

  def date_short(iso)
    parts = iso.split("-")
    months = {
      "01" => "Jan", "02" => "Feb", "03" => "Mar", "04" => "Apr",
      "05" => "May", "06" => "Jun", "07" => "Jul", "08" => "Aug",
      "09" => "Sep", "10" => "Oct", "11" => "Nov", "12" => "Dec"
    }
    day = parts[2]
    if day[0] == "0"
      day = day[1]
    end
    months[parts[1]] + " " + day
  end

  def money(cents)
    whole = cents / 100
    rem = cents % 100
    fraction = rem.to_s
    if rem < 10
      fraction = "0" + fraction
    end
    "$" + whole.to_s + "." + fraction
  end

  def row_line(row)
    row["date"] + "|" + row["model"] + "|" + row["tokens"].to_s + "|" + row["cost_label"]
  end

  def compact_line(row)
    row["name"] + "|" + row["total"].to_s + "|" + row["share"].to_s
  end

  def detail_line(row)
    compact_line(row) + "|" + row["kind"]
  end

  def rebuild
    @rows = []
    @visible_rows = []
    @compact_rows = []
    @detail_rows = []
    @total = 0
    day_index = 0
    @days.each do |day|
      @models.each do |model|
        share = model["share"]
        tokens = 1000 + day.length * share
        @total = @total + tokens
        row = {
          "date" => date_short(day),
          "model" => model["name"],
          "tokens" => tokens,
          "share" => share,
          "cost_label" => money(tokens)
        }
        @rows.push(row)
        if @period == 30 || day_index >= 23
          @visible_rows.push(row)
        end
      end
      day_index = day_index + 1
    end
    index = 0
    while index < 8
      @compact_rows.push({
        "name" => "compact-" + index.to_s,
        "total" => index * 10,
        "share" => index
      })
      @detail_rows.push({
        "name" => "detail-" + index.to_s,
        "total" => index * 10,
        "share" => index,
        "kind" => "model"
      })
      index = index + 1
    end
    @last_line = row_line(@rows.last)
  end

  def set_7
    @period = 7
    rebuild
  end

  def set_30
    @period = 30
    rebuild
  end

  def explode
    rows = []
    index = 0
    while index < 5000
      rows.push("event-row-" + index.to_s)
      index = index + 1
    end
    @last_line = rows.last
  end

  def html
    %Q{
      <div class="screen">
        <p class="count">{@rows.length}</p>
        <p class="visible">{@visible_rows.length}</p>
        <p class="total">{@total}</p>
        <p class="last">{@last_line}</p>
        <div class="rows">
          {each @visible_rows as row}
            <span class="row">{row_line(row)}</span>
          {end}
        </div>
        <div class="compact">
          {each @compact_rows as row}
            <span class="compact-row">{compact_line(row)}</span>
          {end}
        </div>
        <div class="detail">
          {each @detail_rows as row}
            <span class="detail-row">{detail_line(row)}</span>
          {end}
        </div>
        <button class="days-7" onclick="{set_7}">7 days</button>
        <button class="days-30" onclick="{set_30}">30 days</button>
        <button class="explode" onclick="{explode}">Explode</button>
      </div>
    }
  end
end
`;

const oversizedSource = `
class OversizedMount
  @tag_name = "oversized-mount"
  @count

  def initialize
    rows = []
    index = 0
    while index < 5000
      rows.push("retained-row-" + index.to_s)
      index = index + 1
    end
    @count = rows.length
  end

  def html
    %Q{<p class="count">{@count}</p>}
  end
end
`;

const manyRowsSource = `
class ManyRows
  @tag_name = "many-rows"
  @rows

  def initialize
    @rows = []
    index = 0
    while index < 540
      @rows.push({"id" => index, "label" => "row-" + index.to_s})
      index = index + 1
    end
  end

  def row_label(row)
    row["label"]
  end

  def html
    %Q{<div class="rows">{each @rows as row}<span class="row">{row_label(row)}</span>{end}</div>}
  end
end
`;

async function compileProject(capacities?: Record<string, number>): Promise<{
  projectDir: string;
  bundleDir: string;
  server: http.Server;
  baseURL: string;
}> {
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-row-capacity-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "RowScreen.rb"), rowScreenSource);
  fs.writeFileSync(path.join(projectDir, "lib", "OversizedMount.rb"), oversizedSource);
  fs.writeFileSync(path.join(projectDir, "lib", "ManyRows.rb"), manyRowsSource);
  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <script src="mochi-loader.js"></script>
  </head>
  <body><row-screen></row-screen></body>
</html>
`);

  const args = ["-i", projectDir, "-o", bundleDir];
  if (capacities) {
    const configPath = path.join(projectDir, "capacity.json");
    fs.writeFileSync(configPath, JSON.stringify({ schema_version: 1, capacities }));
    args.push("--capacity-config", configPath);
  }

  execFileSync(compilerBinary, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });
  const { server, baseURL } = await startStaticServer(bundleDir);
  return { projectDir, bundleDir, server, baseURL };
}

test("thirty-day model rows and mixed row arities rebuild without forced aggregation", async ({ page }) => {
  test.setTimeout(120_000);
  setupConsoleLogging(page);
  const { projectDir, server, baseURL } = await compileProject();
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    const host = page.locator("row-screen");
    await expect(host.locator("p.count")).toHaveText("180");
    await expect(host.locator("p.visible")).toHaveText("180");
    await expect(host.locator("p.total")).toHaveText("210000");
    await expect(host.locator("p.last")).toHaveText("Nov 9|gpt-oss|1100|$11.00");
    await expect(host.locator(".rows .row")).toHaveCount(180);
    await expect(host.locator(".rows .row").last()).toHaveText("Nov 9|gpt-oss|1100|$11.00");
    await expect(host.locator(".compact .compact-row")).toHaveCount(8);
    await expect(host.locator(".compact .compact-row").last()).toHaveText("compact-7|70|7");
    await expect(host.locator(".detail .detail-row")).toHaveCount(8);
    await expect(host.locator(".detail .detail-row").last()).toHaveText("detail-7|70|7|model");
    const manyRows = await page.evaluate(async () => {
      const element = document.createElement("many-rows");
      document.body.appendChild(element);
      await (element as any)._mochiReady;
      return element.shadowRoot.querySelectorAll(".row").length;
    });
    expect(manyRows).toBe(540);
    const initialStats = await page.evaluate(() => (window as any).MochiLoader.debugStats());

    for (let round = 0; round < 4; round += 1) {
      await host.locator("button.days-7").click();
      await expect(host.locator("p.count")).toHaveText("180");
      await expect(host.locator("p.visible")).toHaveText("42");
      await expect(host.locator(".rows .row")).toHaveCount(42);
      await expect(host.locator(".rows .row").first()).toHaveText("Nov 3|claude-sonnet|1200|$12.00");
      await expect(host.locator(".rows .row").last()).toHaveText("Nov 9|gpt-oss|1100|$11.00");

      await host.locator("button.days-30").click();
      await expect(host.locator("p.count")).toHaveText("180");
      await expect(host.locator("p.visible")).toHaveText("180");
      await expect(host.locator(".rows .row")).toHaveCount(180);
      await expect(host.locator(".rows .row").first()).toHaveText("Oct 11|claude-sonnet|1200|$12.00");
      await expect(host.locator(".rows .row").last()).toHaveText("Nov 9|gpt-oss|1100|$11.00");
      await expect(host.locator(".compact .compact-row")).toHaveCount(8);
      await expect(host.locator(".detail .detail-row")).toHaveCount(8);
    }
    const finalStats = await page.evaluate(() => (window as any).MochiLoader.debugStats());
    expect(finalStats.stateAllocated).toBeLessThanOrEqual(initialStats.stateAllocated + 200);
    expect(finalStats.stateObjects).toBeLessThanOrEqual(initialStats.stateObjects + 200);
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("oversized retained rows report the exhausted scratch resource and keep the VM usable", async ({ page }) => {
  test.setTimeout(120_000);
  setupConsoleLogging(page, { expectedMochiErrors: true });
  const { projectDir, server, baseURL } = await compileProject({ scratch_objects: 512 });
  const errors: string[] = [];
  page.on("pageerror", (err) => errors.push(err.message));

  try {
    await page.goto(`${baseURL}/index.html`);
    await page.waitForFunction(() => Boolean((window as any).customElements.get("row-screen")));

    const constrainedRows = await page.evaluate(async () => {
      const element = document.createElement("many-rows");
      document.body.appendChild(element);
      await (element as any)._mochiReady;
      return element.shadowRoot.querySelectorAll(".row").length;
    });
    expect(constrainedRows).toBe(540);

    const oversized = await page.evaluate(async () => {
      const element = document.createElement("oversized-mount");
      document.body.appendChild(element);
      try {
        await (element as any)._mochiReady;
        return { failed: false, message: "" };
      } catch (error) {
        return { failed: true, message: String((error as Error).message || error) };
      }
    });
    expect(oversized.failed).toBe(true);
    expect(oversized.message).toContain("OversizedMount#initialize");
    expect(oversized.message).toContain("scratch objects exhausted");
    expect(oversized.message).toContain("requested 1");
    expect(oversized.message).toContain("used 512 of 512");
    expect(oversized.message).toContain("lib/OversizedMount.rb:");
    expect(oversized.message).toMatch(/capacity profile [a-f0-9]{64}/);
    expect(oversized.message).not.toContain("component mount failed");

    await page.evaluate(async () => {
      const element = document.createElement("row-screen");
      document.body.appendChild(element);
      await (element as any)._mochiReady;
    });
    const host = page.locator("row-screen").last();
    await expect(host.locator("p.count")).toHaveText("180");
    await host.locator("button.days-7").click();
    await expect(host.locator("p.visible")).toHaveText("42");
    await host.locator("button.explode").click();
    const eventError = await host.evaluate(async (element: any) => {
      await new Promise((resolve) => setTimeout(resolve, 100));
      return element.mochiError ? String(element.mochiError.message || element.mochiError) : "";
    });
    expect(eventError).toContain("RowScreen#explode");
    expect(eventError).toContain("scratch objects exhausted");
    expect(eventError).toContain("requested 1");
    await host.locator("button.days-30").click();
    await expect(host.locator("p.visible")).toHaveText("180");
    await expect(host.locator("p.count")).toHaveText("180");
    expect(errors).toEqual([]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});
