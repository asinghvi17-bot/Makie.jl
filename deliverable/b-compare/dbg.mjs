import { chromium } from '/home/factory/.factory/profiles/personal/tmp/140d0fdd-d7b4-4f4d-8783-448174a8910d.tmp/pw/node_modules/playwright/index.mjs';
import { serve } from './serve.mjs'; import fs from 'node:fs';
const { s, port } = await serve(process.cwd());
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/cmp.html`); await p.waitForFunction(() => window.__result);
const ref = JSON.parse(fs.readFileSync('ft_ref.json'));
const pick = ref.glyphs.filter((g) => 'Hxo.'.includes(String.fromCharCode(g.c)));
const out = await p.evaluate(async (pick) => {
  const mc = new OffscreenCanvas(8, 8).getContext('2d'); const r = [];
  for (const g of pick) { mc.font = '2000px "TeX Gyre Heros Makie"'; const m = mc.measureText(String.fromCharCode(g.c));
    r.push({ ch: String.fromCharCode(g.c), ft: { bx: g.bx * 2000, by: g.by * 2000, w: g.w * 2000, h: g.h * 2000, adv: g.adv * 2000 }, br: { L: m.actualBoundingBoxLeft, R: m.actualBoundingBoxRight, A: m.actualBoundingBoxAscent, D: m.actualBoundingBoxDescent, adv: m.width } }); }
  return r; }, pick);
console.log(JSON.stringify(out, null, 1)); await b.close(); s.close();
