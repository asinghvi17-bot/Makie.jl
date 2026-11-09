// node run_sdf_cmp.mjs sdf_ref.json out.json — in headless Chromium (Playwright); env as host/run_chromium.mjs (PW_MODULE, WASMHOST_DIR, FONT_FILE)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../host/serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [refPath, outPath] = process.argv.slice(2);
const { s, port } = await serve(here, 0, { wh: process.env.WASMHOST_DIR, font: path.dirname(process.env.FONT_FILE), ref: path.dirname(path.resolve(refPath)) });
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const p = await b.newPage();
p.on('console', (m) => console.error('[page]', m.text())); p.on('pageerror', (e) => console.error('[pageerror]', e.message));
await p.goto(`http://127.0.0.1:${port}/sdf_cmp.html`);
await p.waitForFunction(() => window.pageReady);
const res = await p.evaluate((a) => window.runCmp(a), { ref: `/ref/${path.basename(refPath)}`, family: 'TeX Gyre Heros Makie', fontUrl: `/font/${path.basename(process.env.FONT_FILE)}` });
fs.writeFileSync(outPath, JSON.stringify(res));
await b.close(); s.close();
const eq = res.rows.filter((r) => r.max_abs !== undefined);
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
const med = (a) => [...a].sort((x, y) => x - y)[a.length >> 1];
console.log(JSON.stringify({ ua: res.ua, glyphs: res.rows.length, tile_dims_equal: eq.length,
  max_abs_over_equal: Math.max(...eq.map((r) => r.max_abs)), mean_abs_over_equal: mean(eq.map((r) => r.mean_abs)),
  max_abs_f16: Math.max(...eq.map((r) => r.max_abs_f16)), mean_abs_f16: mean(eq.map((r) => r.mean_abs_f16)),
  raster_ms_mean: mean(res.rasterMs), sdf_ms_best_mean: mean(res.rows.map((r) => r.sdf_ms_best)), sdf_ms_best_median: med(res.rows.map((r) => r.sdf_ms_best)),
  native_sdf_ms: res.native_sdf_ms }, null, 1));
