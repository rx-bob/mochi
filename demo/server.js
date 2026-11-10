const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DEMO = __dirname;
const POC = path.join(ROOT, 'poc_yiseq');
const PORT = Number(process.env.PORT || 9844);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.rb': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.wasm': 'application/wasm',
  '.chi': 'application/octet-stream',
  '.dat': 'application/octet-stream',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const USERS = JSON.stringify([
  { name: 'Alice', role: 'Engineer' },
  { name: 'Bob', role: 'Designer' },
  { name: 'Charlie', role: 'PM' },
  { name: 'Diana', role: 'Engineer' },
  { name: 'Eve', role: 'DevOps' },
]);

function within(base, target) {
  return target === base || target.startsWith(base + path.sep);
}

function resolvePath(pathname) {
  if (pathname === '/' || pathname === '/demo' || pathname === '/demo/') {
    return path.join(DEMO, 'index.html');
  }

  if (pathname.startsWith('/demo/')) {
    const target = path.resolve(DEMO, pathname.slice('/demo/'.length));
    return within(DEMO, target) ? target : null;
  }

  if (pathname.startsWith('/poc_yiseq/')) {
    const target = path.resolve(ROOT, pathname.slice(1));
    return within(POC, target) ? target : null;
  }

  return null;
}

function sendJson(res, body) {
  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

http.createServer((req, res) => {
  let pathname;

  try {
    pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  } catch (_) {
    res.writeHead(400);
    res.end('Bad request');
    return;
  }

  if (pathname === '/api/users') {
    sendJson(res, USERS);
    return;
  }

  if (pathname === '/favicon.ico') {
    res.writeHead(204);
    res.end();
    return;
  }

  const filePath = resolvePath(pathname);
  if (!filePath) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  let stat;
  try {
    stat = fs.statSync(filePath);
    if (stat.isDirectory()) {
      const indexPath = path.join(filePath, 'index.html');
      stat = fs.statSync(indexPath);
      return sendFile(req, res, indexPath, stat);
    }
  } catch (_) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  sendFile(req, res, filePath, stat);
}).listen(PORT, () => {
  console.log(`Mochi MyCounter demo → http://localhost:${PORT}`);
  console.log('  demo page:   /');
  console.log('  assets:      /poc_yiseq/*');
  console.log('  mock API:    /api/users');
});

function sendFile(req, res, filePath, stat) {
  const ext = path.extname(filePath).toLowerCase();
  const headers = {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Content-Length': stat.size,
    'Cache-Control': ext === '.html' ? 'no-store' : 'no-cache',
  };

  res.writeHead(200, headers);
  if (req.method === 'HEAD') {
    res.end();
    return;
  }

  fs.createReadStream(filePath).pipe(res);
}
