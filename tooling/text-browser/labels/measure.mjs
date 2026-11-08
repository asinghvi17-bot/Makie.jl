// node measure.mjs MISSING.tsv METRICS.tsv — the browser's measurements for BrowserLabels' TableMetrics (appends to METRICS.tsv).
// Needs PW_MODULE, PLAYWRIGHT_BROWSERS_PATH, FONT_DIR (Makie's assets/fonts).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../host/serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [missingPath, outPath] = process.argv.slice(2);
const unesc = (s) => s.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
const reqs = fs.readFileSync(missingPath, 'utf8').split('\n').filter(Boolean).map((l) => l.split('\t'));
const { s, port } = await serve(here, 0, { fonts: process.env.FONT_DIR });
const b = await chromium.launch();
const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/measure.html`);
await p.waitForFunction(() => window.ready);
const lines = await p.evaluate(async (reqs) => {
  const out = [];
  const mc = new OffscreenCanvas(8, 8).getContext('2d');
  const font = (key, px) => { const [style, family] = key.split('|'); return `${style ? style + ' ' : ''}${px}px "${family}"`; };
  for (const [kind, key, ...rest] of reqs) {
    if (kind === 'F') {
      mc.font = font(key, 1000); const m = mc.measureText('x');
      const el = document.createElement('span');
      el.style.cssText = `position:absolute;visibility:hidden;white-space:pre;line-height:normal;font:${font(key, 1000)}`; el.textContent = 'x'; document.body.appendChild(el);
      const h = el.getBoundingClientRect().height / 1000; el.remove();
      out.push(['F', key, m.fontBoundingBoxAscent / 1000, -m.fontBoundingBoxDescent / 1000, h].join('\t'));
    } else if (kind === 'W') {
      const px = Number(rest[0]), str = rest.slice(1).join('\t').replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
      mc.font = font(key, px);
      // the width the DOM / fillText will use at this size
      out.push(['W', key, rest[0], rest.slice(1).join('\t'), mc.measureText(str).width].join('\t'));
    }
  }
  return out;
}, reqs);
fs.appendFileSync(outPath, lines.join('\n') + '\n');
console.log(`measured ${lines.length} entries`);
await b.close(); s.close();
