const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const PORT = 8090;
const DIR = __dirname;

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.wasm': 'application/wasm',
  '.mrb':  'application/octet-stream',
  '.css':  'text/css',
};

http.createServer((req, res) => {
  const filePath = path.join(DIR, req.url === '/' ? 'index.html' : req.url);
  const ext = path.extname(filePath);

  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  const raw = fs.readFileSync(filePath);
  const mime = MIME[ext] || 'application/octet-stream';
  const acceptEncoding = req.headers['accept-encoding'] || '';

  if (acceptEncoding.includes('gzip')) {
    const gzipped = zlib.gzipSync(raw);
    res.writeHead(200, {
      'Content-Type': mime,
      'Content-Encoding': 'gzip',
      'Content-Length': gzipped.length,
      'Cache-Control': 'no-cache',
    });
    res.end(gzipped);
  } else {
    res.writeHead(200, {
      'Content-Type': mime,
      'Content-Length': raw.length,
      'Cache-Control': 'no-cache',
    });
    res.end(raw);
  }
}).listen(PORT, () => {
  console.log(`Mochi PoC server (gzip enabled) → http://localhost:${PORT}`);
});
