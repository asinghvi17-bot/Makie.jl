import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
export function serve(root, port = 0, extra = {}) {
  const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.otf': 'font/otf', '.wasm': 'application/wasm' };
  const s = http.createServer((req, res) => {
    const u = decodeURIComponent(req.url.split('?')[0]);
    const roots = [root, ...Object.values(extra)];
    const prefix = Object.keys(extra).find((k) => u.startsWith('/' + k + '/'));
    const file = prefix ? path.join(extra[prefix], u.slice(prefix.length + 2)) : path.join(root, u);
    fs.readFile(file, (err, buf) => {
      if (err) { res.writeHead(404); res.end('nf'); return; }
      res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'access-control-allow-origin': '*' }); res.end(buf);
    });
  });
  return new Promise((r) => s.listen(port, '127.0.0.1', () => r({ s, port: s.address().port })));
}
