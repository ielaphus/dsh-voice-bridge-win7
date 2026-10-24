// fetch.js — HTTPS downloader with redirects (shell TLS is dead on this host).
// usage: node fetch.js <url> <destPath>
'use strict';
const https = require('node:https');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const url = process.argv[2];
const dest = process.argv[3];
if (!url || !dest) {
  console.log('usage: fetch.js <url> <dest>');
  process.exit(2);
}

const started = Date.now();
let total = 0;

function download(current, depth) {
  if (depth > 10) {
    console.log('ERR too many redirects');
    process.exit(1);
  }
  const lib = current.startsWith('https:') ? https : http;
  const req = lib.get(
    current,
    { headers: { 'user-agent': 'dsh-voice-fetch' } },
    (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        download(new URL(res.headers.location, current).toString(), depth + 1);
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        console.log('http_status=' + res.statusCode);
        process.exit(1);
      }
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      const out = fs.createWriteStream(dest);
      res.on('data', (chunk) => {
        total += chunk.length;
      });
      res.pipe(out);
      out.on('finish', () => {
        console.log('OK bytes=' + String(total) + ' ms=' + String(Date.now() - started));
      });
      out.on('error', (e) => {
        console.log('ERR write ' + e.message);
        process.exit(1);
      });
    },
  );
  req.on('error', (e) => {
    console.log('ERR ' + e.message);
    process.exit(1);
  });
  req.setTimeout(120000, () => {
    console.log('ERR timeout');
    req.destroy();
    process.exit(1);
  });
}

download(url, 0);
