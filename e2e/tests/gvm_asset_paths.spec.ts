import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test, expect } from "@playwright/test";

const repoRoot = path.resolve(__dirname, "..", "..");
const compilerBinary = path.join(repoRoot, "compiler", "mochi");
const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".chi": "application/octet-stream",
  ".svg": "image/svg+xml",
  ".css": "text/css; charset=utf-8",
  ".woff2": "font/woff2",
};

function startStaticServer(rootDir: string): Promise<{ server: http.Server; baseURL: string }> {
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url || "/").split("?")[0].split("#")[0]);
    const relative = requestPath.replace(/^\/+/, "") + (requestPath.endsWith("/") ? "index.html" : "");
    const filePath = path.resolve(rootDir, relative);
    if (filePath !== rootDir && !filePath.startsWith(rootDir + path.sep)) {
      response.writeHead(403).end();
      return;
    }
    fs.readFile(filePath, (error, data) => {
      if (error && path.extname(relative) === "") {
        fs.readFile(path.join(rootDir, "index.html"), (indexError, indexData) => {
          if (indexError) return void response.writeHead(404).end();
          response.writeHead(200, { "content-type": CONTENT_TYPES[".html"] }).end(indexData);
        });
        return;
      }
      if (error) return void response.writeHead(404).end();
      response.writeHead(200, {
        "content-type": CONTENT_TYPES[path.extname(filePath)] || "application/octet-stream",
      }).end(data);
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

test("icon resources resolve from manifest on root and prefixed deep routes", async ({ page }) => {
  test.setTimeout(180_000);
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-asset-paths-"));
  const bundleDir = path.join(projectDir, "bundle");
  fs.mkdirSync(path.join(projectDir, "lib"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "icons"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "lib", "AssetProbe.rb"), `
class AssetProbe
  @tag_name = "asset-probe"
  def html
    %Q{<span>{Mochi.raw(MochiIcons.icon("home"))}</span>}
  end
end
`);
  fs.writeFileSync(path.join(projectDir, "icons", "home.svg"),
    '<svg id="mochi-icon" viewBox="0 0 24 24"><path d="M3 12h18"/></svg>');
  fs.writeFileSync(path.join(projectDir, "icons", "unused.svg"),
    '<svg id="mochi-icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/></svg>');
  fs.writeFileSync(path.join(projectDir, "index.html"), `<!doctype html>
<html><head><script src="/mochi-loader.js"></script></head>
<body><asset-probe></asset-probe><a href="/next/deep?tab=2#view">Next</a></body></html>`);

  execFileSync(compilerBinary, ["-i", projectDir, "-o", bundleDir], {
    cwd: repoRoot, encoding: "utf8", stdio: "pipe",
  });
  expect(fs.existsSync(path.join(bundleDir, "mochi-icons", "home.svg"))).toBe(true);
  expect(fs.existsSync(path.join(bundleDir, "mochi-icons", "unused.svg"))).toBe(false);

  const deploymentDir = path.join(projectDir, "deployment");
  fs.mkdirSync(path.join(deploymentDir, "tenant", "assets"), { recursive: true });
  fs.cpSync(bundleDir, path.join(deploymentDir, "tenant", "assets"), { recursive: true });
  fs.writeFileSync(path.join(deploymentDir, "index.html"), `<!doctype html>
<html><head><base href="/tenant/"><script src="/tenant/assets/mochi-loader.js" data-mochi-manifest="/tenant/assets/mochi-manifest.json"></script></head>
<body><asset-probe></asset-probe><a href="/tenant/next/deep?tab=2#view">Next</a></body></html>`);

  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));
  const rootServer = await startStaticServer(bundleDir);
  const deploymentServer = await startStaticServer(deploymentDir);
  try {
    await page.goto(`${rootServer.baseURL}/deep/entry?from=root#icon`);
    const rootUse = page.locator("asset-probe").locator("svg use");
    await expect(rootUse).toHaveAttribute("href", `${rootServer.baseURL}/mochi-icons/home.svg#mochi-icon`);
    await expect(page.locator("asset-probe")).toBeVisible();
    await page.getByRole("link", { name: "Next" }).click();
    await expect(page).toHaveURL(`${rootServer.baseURL}/next/deep?tab=2#view`);
    await expect(page.locator("asset-probe").locator("svg use")).toHaveAttribute(
      "href", `${rootServer.baseURL}/mochi-icons/home.svg#mochi-icon`);

    await page.goto(`${deploymentServer.baseURL}/tenant/deep/entry?from=prefix#icon`);
    const prefixedHref = `${deploymentServer.baseURL}/tenant/assets/mochi-icons/home.svg#mochi-icon`;
    await expect(page.locator("asset-probe").locator("svg use")).toHaveAttribute("href", prefixedHref);
    await page.getByRole("link", { name: "Next" }).click();
    await expect(page).toHaveURL(`${deploymentServer.baseURL}/tenant/next/deep?tab=2#view`);
    await expect(page.locator("asset-probe").locator("svg use")).toHaveAttribute("href", prefixedHref);
    expect(requested).toContain(`${deploymentServer.baseURL}/tenant/assets/mochi-icons/home.svg`);
    expect(requested.some((url) => url.includes("unused.svg"))).toBe(false);
  } finally {
    await Promise.all([
      new Promise<void>((resolve) => rootServer.server.close(() => resolve())),
      new Promise<void>((resolve) => deploymentServer.server.close(() => resolve())),
    ]);
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("the static station inspector loads only its mounted components under a nested prefix", async ({ page }) => {
  test.setTimeout(180_000);
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-inspector-prefix-"));
  const prefix = "/deployments/tenant/stations/";
  const bundle = path.join(temp, prefix);
  let server: http.Server | undefined;
  try {
    execFileSync(compilerBinary, [
      "-i", path.join(repoRoot, "e2e", "fixtures", "clay_inspector"), "-o", bundle,
    ], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
    const readJSON = (file: string) => JSON.parse(fs.readFileSync(path.join(bundle, file), "utf8"));
    const manifest = readJSON("mochi-manifest.json");
    const componentFiles = (tag: string): string[] => {
      const entry = manifest.components.find((entry: { tag_name: string }) => entry.tag_name === tag);
      const descriptor = readJSON(entry.descriptor);
      const styleIds: string[] = [...(descriptor.style_resources ?? [])];
      if (descriptor.document_style) styleIds.push(descriptor.document_style);
      return [
        entry.descriptor,
        manifest.packages[entry.package].file,
        ...styleIds.map((id) => manifest.resources[id].file),
      ];
    };
    const resourceFiles = Object.values<{ kind: string; file: string }>(manifest.resources);
    const fontFiles = resourceFiles.filter((resource) => resource.kind === "font").map((resource) => resource.file);
    expect(fontFiles).toHaveLength(3);
    const root = componentFiles("record-inspector");
    const row = componentFiles("station-row");
    const details = componentFiles("station-details");
    const initial = new Set([
      "", "mochi-loader.js", "mochi-manifest.json", "mochi-gvm.js", "mochi-gvm.wasm",
      ...root, ...row, ...fontFiles, manifest.packages["ruby:lib/station_numbers.rb"].file,
      manifest.packages["ruby:lib/station_records.rb"].file,
    ]);
    const later = details.filter((file) => !initial.has(file));
    expect(later).toEqual([
      "components/station-details.json", "components/station-details.chi",
      expect.stringMatching(/^components\/styles\/.+\.css$/),
    ]);

    const staticHost = await startStaticServer(temp);
    server = staticHost.server;
    const deploymentURL = new URL(prefix, staticHost.baseURL);
    const urls = (files: Iterable<string>) => [...files].map((file) => new URL(file, deploymentURL).href).sort();
    const requested: string[] = [];
    const successful = new Set<string>();
    page.on("request", (request) => requested.push(request.url()));
    page.on("response", (response) => {
      if (response.ok()) successful.add(response.url());
    });

    await page.goto(deploymentURL.href);
    const inspector = page.locator("record-inspector");
    const open = inspector.getByRole("button", { name: "Details" });
    await expect(inspector.getByText("Station records Ω")).toBeVisible();
    await expect(inspector.getByRole("button", { name: /Café/ })).toBeVisible();
    await expect(open).toHaveCSS("padding-top", "8px");
    await page.evaluate(() => document.fonts.ready.then(() => undefined));
    await expect.poll(() => [...successful].sort()).toEqual(urls(initial));
    expect([...new Set(requested)].sort()).toEqual(urls(initial));
    const beforeDetails = requested.length;

    await inspector.getByRole("button", { name: /Café/ }).click();
    await open.click();
    const confirm = inspector.getByRole("button", { name: "Confirm station" });
    await expect(confirm).toHaveJSProperty("tagName", "BUTTON");
    await expect(confirm).toHaveCSS("background-color", "rgb(38, 99, 79)");
    expect(await confirm.evaluate(async (button) => {
      const family = getComputedStyle(button).fontFamily.split(",")[0].replace(/["']/g, "");
      await document.fonts.ready;
      return family.startsWith("MochiFont-") && Array.from(document.fonts).some(
        (face) => face.family === family && face.status === "loaded",
      );
    })).toBe(true);
    await confirm.click();
    await expect(inspector.getByText("102: Café / 1 / parent")).toBeVisible();
    await expect(page.locator("canvas")).toHaveCount(0);

    const all = urls([...initial, ...later]);
    await expect.poll(() => [...successful].sort()).toEqual(all);
    expect(requested.slice(beforeDetails).sort()).toEqual(urls(later));

    const beforeEditor = requested.length;
    await inspector.getByRole("button", { name: "Edit station" }).click();
    await expect(inspector.getByRole("textbox", { name: "Station name" })).toHaveValue("Café");
    const editRequests = [...componentFiles("station-editor").filter((file) => !initial.has(file)),
      manifest.capabilities.editing.host];
    await expect.poll(() => [...successful].sort()).toEqual(urls([...initial, ...later, ...editRequests]));
    expect(requested.slice(beforeEditor).sort()).toEqual(urls(editRequests));
  } finally {
    if (server) await new Promise<void>((resolve) => server!.close(() => resolve()));
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
