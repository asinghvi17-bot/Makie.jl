// node shoot.mjs URL LABELS.json OUTPREFIX MODES(comma: none,dom,canvas) — screenshots of the WGLMakie page (headless Chromium), with the label renderers on top.
// Needs PW_MODULE, PLAYWRIGHT_BROWSERS_PATH, FONT_DIR.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../host/serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [url, labelsPath, outPrefix, modes = 'none'] = process.argv.slice(2);
const data = labelsPath !== '-' ? JSON.parse(fs.readFileSync(labelsPath, 'utf8')) : null;
const { s, port } = await serve(here, 0, { fonts: process.env.FONT_DIR });
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
for (const mode of modes.split(',')) {
  const p = await b.newPage({ viewport: { width: 640, height: 450 }, deviceScaleFactor: Number(process.env.DPR ?? 1) });
  p.on('pageerror', (e) => console.error('[pageerror]', e.message));
  await p.goto(url);
  await p.waitForSelector('canvas', { timeout: 180000 });
  await p.waitForTimeout(5000);
  const rect = await p.evaluate(async ({ mode, data, port }) => {
    const cv = document.querySelector('canvas'); const host = cv.parentElement;
    host.style.position = 'relative';
    if (mode !== 'none') {
      // the page's fonts, as an app would declare them
      for (const [f, style, weight] of [['TeXGyreHerosMakie-Regular.otf', 'normal', '400'], ['TeXGyreHerosMakie-Bold.otf', 'normal', '700'], ['TeXGyreHerosMakie-Italic.otf', 'italic', '400'], ['TeXGyreHerosMakie-BoldItalic.otf', 'italic', '700']]) {
        const ff = new FontFace('TeX Gyre Heros Makie', `url(http://127.0.0.1:${port}/fonts/${f})`, { style, weight }); await ff.load(); document.fonts.add(ff);
      }
      const m = await import(`http://127.0.0.1:${port}/overlay.mjs`);
      (mode === 'dom' ? m.mountDomOverlay : m.mountCanvasLayer)(host, data);
      await new Promise((r) => setTimeout(r, 500));
    }
    const r = cv.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height };
  }, { mode, data, port });
  await p.screenshot({ path: `${outPrefix}_${mode}.png`, clip: rect });
  if (mode === 'dom') {   // PNG export as WGLMakie does it (the canvas), which does not contain DOM elements
    const png = await p.evaluate(() => document.querySelector('canvas').toDataURL('image/png'));
    fs.writeFileSync(`${outPrefix}_${mode}_canvas_export.png`, Buffer.from(png.split(',')[1], 'base64'));
  }
  console.log(mode, JSON.stringify(rect));
  await p.close();
}
await b.close(); s.close();
