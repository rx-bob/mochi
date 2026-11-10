const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const PORT = 8090;
const DIR = __dirname;

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.wasm': 'application/wasm',
  '.chi':  'application/octet-stream',
  '.css':  'text/css',
  '.dat':  'application/octet-stream',
};

// Mock API endpoints
const API_ROUTES = {
  '/api/users': JSON.stringify([
    { name: 'Alice', role: 'Engineer' },
    { name: 'Bob', role: 'Designer' },
    { name: 'Charlie', role: 'PM' },
    { name: 'Diana', role: 'Engineer' },
    { name: 'Eve', role: 'DevOps' },
  ]),
};

// Compute dictionary hash on startup (for Available-Dictionary matching)
let dictHash = null;
let dictPath = path.join(DIR, 'mochi-dict.dat');
if (fs.existsSync(dictPath)) {
  const dictBuf = fs.readFileSync(dictPath);
  dictHash = crypto.createHash('sha256').update(dictBuf).digest('base64');
  console.log('Dictionary loaded, SHA-256:', dictHash);
}

http.createServer((req, res) => {
  // Handle mock API routes
  if (API_ROUTES[req.url]) {
    const body = API_ROUTES[req.url];
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'no-cache',
    });
    res.end(body);
    return;
  }

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
  const availableDict = req.headers['available-dictionary'] || '';

  // Debug: log .chi request headers
  if (ext === '.chi') {
    console.log(`\n  [DEBUG] ${req.url}`);
    console.log(`    Accept-Encoding: ${acceptEncoding}`);
    console.log(`    Available-Dictionary: ${availableDict || '(none)'}`);
  }

  // --- Compression Dictionary Transport for .chi files ---
  if (ext === '.chi' && availableDict && dictHash && acceptEncoding.includes('dcz')) {
    // Client has our dictionary and accepts dcz — serve dictionary-compressed zstd
    const dczPath = filePath + '.dcz';
    if (fs.existsSync(dczPath)) {
      const dczData = fs.readFileSync(dczPath);

      // RFC 9842: Shared Zstandard envelope = skippable frame (8 bytes) + SHA-256 hash (32 bytes) + zstd data
      const magic = Buffer.from([0x5e, 0x2a, 0x4d, 0x18, 0x20, 0x00, 0x00, 0x00]);
      const hashBuf = crypto.createHash('sha256').update(fs.readFileSync(dictPath)).digest();
      const frame = Buffer.concat([magic, hashBuf, dczData]);

      res.writeHead(200, {
        'Content-Type': mime,
        'Content-Encoding': 'dcz',
        'Content-Length': frame.length,
        'Vary': 'accept-encoding, available-dictionary',
        'Cache-Control': 'no-cache',
      });
      res.end(frame);
      console.log(`  ${req.url}: dcz ${frame.length}B (dict-compressed, raw ${raw.length}B)`);
      return;
    }
  }

  // --- Dictionary file: advertise as dictionary for .chi files ---
  if (req.url === '/mochi-dict.dat') {
    const headers = {
      'Content-Type': mime,
      'Cache-Control': 'max-age=31536000',
      'Use-As-Dictionary': 'match="/*.chi"',
    };

    if (acceptEncoding.includes('gzip')) {
      const gzipped = zlib.gzipSync(raw);
      headers['Content-Encoding'] = 'gzip';
      headers['Content-Length'] = gzipped.length;
      res.writeHead(200, headers);
      res.end(gzipped);
    } else {
      headers['Content-Length'] = raw.length;
      res.writeHead(200, headers);
      res.end(raw);
    }
    return;
  }

  // --- Default: gzip compression ---
  const headers = {
    'Content-Type': mime,
    'Cache-Control': 'no-cache',
  };

  // For .chi files, add Vary so caches distinguish dict vs non-dict responses
  if (ext === '.chi') {
    headers['Vary'] = 'accept-encoding, available-dictionary';
  }

  if (acceptEncoding.includes('gzip')) {
    const gzipped = zlib.gzipSync(raw);
    headers['Content-Encoding'] = 'gzip';
    headers['Content-Length'] = gzipped.length;
    res.writeHead(200, headers);
    res.end(gzipped);
  } else {
    headers['Content-Length'] = raw.length;
    res.writeHead(200, headers);
    res.end(raw);
  }
}).listen(PORT, () => {
  console.log(`Mochi PoC server (gzip + dict transport) → http://localhost:${PORT}`);
});
