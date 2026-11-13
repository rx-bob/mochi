import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..");
const compiler = path.join(repoRoot, "compiler", "mochi");
const fixture = path.join(__dirname, "..", "fixtures", "framework_contracts");

export async function withFrameworkProject<T>(run: (baseURL: string) => Promise<T>, body = "<contract-root></contract-root>"): Promise<T> {
  return withCompiledProject(fixture, run, body);
}

export async function withCompiledProject<T>(fixture: string, run: (baseURL: string, bundle: string) => Promise<T>, body?: string): Promise<T> {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-framework-"));
  const bundle = path.join(project, "bundle");
  const server = http.createServer((request, response) => {
    const pathname = decodeURIComponent((request.url || "/").split("?")[0]).replace(/^\/+/, "");
    const file = path.resolve(bundle, pathname || "index.html");
    if (file !== bundle && !file.startsWith(bundle + path.sep)) {
      response.writeHead(403).end();
      return;
    }
    fs.readFile(file, (error, content) => {
      if (error) {
        response.writeHead(404).end();
        return;
      }
      const type = path.extname(file) === ".wasm" ? "application/wasm" :
        path.extname(file) === ".js" ? "text/javascript" :
        path.extname(file) === ".json" ? "application/json" :
        path.extname(file) === ".chi" ? "application/octet-stream" :
        path.extname(file) === ".svg" ? "image/svg+xml" : "text/html; charset=utf-8";
      response.writeHead(200, { "content-type": type }).end(content);
    });
  });

  try {
    fs.cpSync(fixture, project, { recursive: true });
    if (body !== undefined) fs.writeFileSync(path.join(project, "index.html"), `<!doctype html><html><head><meta charset="utf-8"><script src="mochi-loader.js"></script></head><body>${body}</body></html>`);
    fs.mkdirSync(bundle);
    execFileSync(compiler, ["-i", project, "-o", bundle], { cwd: repoRoot, stdio: "pipe" });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("framework fixture server did not bind");
    return await run(`http://127.0.0.1:${address.port}`, bundle);
  } finally {
    if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(project, { recursive: true, force: true });
  }
}
