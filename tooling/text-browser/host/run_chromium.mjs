// node run_chromium.mjs MODULE.wasm OUT.json [TEXT] — runs a text probe in headless Chromium (Playwright).
// Needs: PLAYWRIGHT_BROWSERS_PATH, PW_MODULE (the playwright package), SHIM_DIR (@bjorn3/browser_wasi_shim/dist),
//        WASMHOST_DIR, WASMCODEGEN_DIR, FONT_FILE (TeXGyreHerosMakie-Regular.otf)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from './serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [wasmPath, outPath, text = 'Wasm: ünï 42 ΩΣ ≈ ∞'] = process.argv.slice(2);
const { s, port } = await serve(here, 0, { shim: process.env.SHIM_DIR, wh: process.env.WASMHOST_DIR, wcg: process.env.WASMCODEGEN_DIR, labels: path.join(here, '..', 'labels'),
                                           wasm: path.dirname(path.resolve(wasmPath)), font: path.dirname(process.env.FONT_FILE) });
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const p = await b.newPage();
p.on('console', (m) => console.error('[page]', m.text())); p.on('pageerror', (e) => console.error('[pageerror]', e.message));
await p.goto(`http://127.0.0.1:${port}/page.html`);
await p.waitForFunction(() => window.pageReady);
const res = await p.evaluate((a) => window.runModule(a), {
  wasm: `/wasm/${path.basename(wasmPath)}`, text,
  fonts: [{ family: 'TeX Gyre Heros Makie', url: `/font/${path.basename(process.env.FONT_FILE)}` }],
});
fs.writeFileSync(outPath, JSON.stringify(res, null, 1));
// OVERLAY_PNG=path: the module printed a `LABELS {json}` line (probe C): show it as a DOM overlay and as a Canvas2D layer, side by side
if (process.env.OVERLAY_PNG) {
  const line = res.stdout.find((l) => l.startsWith('LABELS '));
  const data = JSON.parse(line.slice(7));
  await p.evaluate(async ({ data, port }) => {
    document.body.innerHTML = '<div style="display:flex;gap:10px;padding:10px;background:#ddd"><div id=a style="position:relative;background:#fff"></div><div id=b style="position:relative;background:#fff"></div></div>';
    const m = await import(`http://127.0.0.1:${port}/labels/overlay.mjs`);
    for (const id of ['a', 'b']) { const el = document.getElementById(id); el.style.width = data.width + 'px'; el.style.height = data.height + 'px'; }
    m.mountDomOverlay(document.getElementById('a'), data);
    m.mountCanvasLayer(document.getElementById('b'), data);
    await new Promise((r) => setTimeout(r, 300));
  }, { data, port });
  await p.screenshot({ path: process.env.OVERLAY_PNG });
}
console.log(res.stdout.join('\n'));
console.error(`rc=${res.rc} ${res.ms?.toFixed(0)} ms ${JSON.stringify(res.stats)} ${res.userAgent}`);
await b.close(); s.close();
