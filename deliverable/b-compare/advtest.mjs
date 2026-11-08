// advance width at several canvas font sizes vs FreeType (ft_ref.json). node advtest.mjs (PW_MODULE = playwright's index.mjs), cwd = this directory
import fs from 'node:fs';
import { serve } from './serve.mjs';
const { chromium } = await import(process.env.PW_MODULE);
const { s, port } = await serve(process.cwd());
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/cmp.html`); await p.waitForFunction(() => window.__result);
const ref = JSON.parse(fs.readFileSync('ft_ref.json'));
const out = await p.evaluate(async (ref) => {
  const mc = new OffscreenCanvas(8, 8).getContext('2d'); const r = {};
  for (const px of [1000, 2000, 2048, 4096, 8192, 16384, 32768]) { let mx = 0, sum = 0;
    for (const g of ref.glyphs) { mc.font = `${px}px "TeX Gyre Heros Makie"`; const e = Math.abs(mc.measureText(String.fromCodePoint(g.c)).width / px - g.adv) * 1000; mx = Math.max(mx, e); sum += e; }
    r[px] = { max_units_per_1000em: mx, mean: sum / ref.glyphs.length }; }
  return r; }, ref);
console.log(JSON.stringify(out)); await b.close(); s.close();
