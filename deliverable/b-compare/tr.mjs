// text-rendering modes: width of "0" and of a label at 14 px, canvas measureText vs DOM, vs linear scaling of a 4000 px measure
import { serve } from './serve.mjs';
const { chromium } = await import(process.env.PW_MODULE);
const { s, port } = await serve(process.cwd());
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/cmp.html`); await p.waitForFunction(() => window.__result);
const out = await p.evaluate(() => {
  const r = {}; const mc = new OffscreenCanvas(8, 8).getContext('2d');
  for (const tr of ['auto', 'optimizeSpeed', 'optimizeLegibility', 'geometricPrecision']) {
    mc.textRendering = tr; mc.font = '14px "TeX Gyre Heros Makie"';
    const el = document.createElement('span'); el.style.cssText = `position:absolute;white-space:pre;font:14px "TeX Gyre Heros Makie";text-rendering:${tr}`; el.textContent = '0.5 time (s)'; document.body.appendChild(el);
    r[tr] = { canvas0: mc.measureText('0').width, canvasStr: mc.measureText('0.5 time (s)').width, domStr: el.getBoundingClientRect().width }; el.remove();
  }
  mc.textRendering = 'auto'; mc.font = '4000px "TeX Gyre Heros Makie"'; r.linear = { zero14: mc.measureText('0').width / 4000 * 14, str14: mc.measureText('0.5 time (s)').width / 4000 * 14 };
  return r; });
console.log(JSON.stringify(out, null, 1)); await b.close(); s.close();
