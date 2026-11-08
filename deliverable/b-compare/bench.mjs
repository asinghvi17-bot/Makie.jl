// host-side cost: Canvas2D raster of a 320 px glyph (fillText + getImageData + bbox scan) and a measureText job. WASMHOST_DIR = the patched WasmHost clone
import { serve } from './serve.mjs';
const { chromium } = await import(process.env.PW_MODULE);
const { s, port } = await serve(process.cwd(), 0, { wh: process.env.WASMHOST_DIR });
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/cmp.html`); await p.waitForFunction(() => window.__result);
const out = await p.evaluate(async (port) => {
  const m = await import(`http://127.0.0.1:${port}/wh/js/browser/text.mjs`); const be = m.browserBackend();
  const t0 = performance.now(); for (let cp = 33; cp < 127; cp++) await be.glyph({ style: '', family: 'TeX Gyre Heros Makie', cp, px: 320 }); const t1 = performance.now();
  const t2 = performance.now(); for (let i = 0; i < 200; i++) await be.measure({ style: '', family: 'TeX Gyre Heros Makie', px: 14, text: '0.5 time (s) ' + i }); const t3 = performance.now();
  return { glyph320_ms_each: (t1 - t0) / 94, measure_ms_each: (t3 - t2) / 200 };
}, port);
console.log(JSON.stringify(out)); await b.close(); s.close();
