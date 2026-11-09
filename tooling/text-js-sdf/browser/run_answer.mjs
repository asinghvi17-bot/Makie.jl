// node run_answer.mjs missing.txt table.tsv — answers the base64 requests in missing.txt (one per line) in headless Chromium, appends to table.tsv
// env: PW_MODULE, WASMHOST_DIR, FONT_DIR (the four TeXGyreHerosMakie-*.otf)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../host/serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [missing, table] = process.argv.slice(2);
const reqs = fs.readFileSync(missing, 'utf8').split('\n').filter(Boolean);
const { s, port } = await serve(here, 0, { wh: process.env.WASMHOST_DIR, fonts: process.env.FONT_DIR });
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const p = await b.newPage();
p.on('pageerror', (e) => console.error('[pageerror]', e.message));
await p.goto(`http://127.0.0.1:${port}/answer.html`);
await p.waitForFunction(() => window.pageReady);
const F = (f, style, weight) => ({ family: 'TeX Gyre Heros Makie', url: `/fonts/${f}`, style, weight });
const res = await p.evaluate((a) => window.answer(a), {
  requests: reqs.map((r) => Buffer.from(r, 'base64').toString('utf8')),
  fonts: [F('TeXGyreHerosMakie-Regular.otf', 'normal', '400'), F('TeXGyreHerosMakie-Bold.otf', 'normal', '700'), F('TeXGyreHerosMakie-Italic.otf', 'italic', '400'), F('TeXGyreHerosMakie-BoldItalic.otf', 'italic', '700')],
});
fs.appendFileSync(table, reqs.map((r, i) => `${r}\t${res.out[i]}\n`).join(''));
console.log(`answered ${reqs.length} requests`, JSON.stringify(res.stats));
await b.close(); s.close();
