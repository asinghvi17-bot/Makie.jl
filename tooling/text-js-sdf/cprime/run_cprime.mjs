// node run_cprime.mjs URL native|sprite OUTPREFIX — screenshots of the 3D label scene: initial view, and after an orbit drag (the camera moves in the browser).
// sprite: adds the canvas-texture labels (label_sprites.mjs) once the page's WGLMakie scene exists. Also saves the canvas PNG export (toDataURL).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../host/serve.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PW_MODULE);
const [url, variant, outPrefix] = process.argv.slice(2);
const { s, port } = await serve(here, 0, { fonts: process.env.FONT_DIR });
const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const p = await b.newPage({ viewport: { width: 640, height: 450 }, deviceScaleFactor: 1 });
p.on('pageerror', (e) => console.error('[pageerror]', e.message));
p.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
await p.goto(url);
await p.waitForSelector('canvas', { timeout: 180000 });
await p.waitForTimeout(4000);
if (variant === 'sprite') {
  await p.evaluate(async ({ port }) => {
    const ff = new FontFace('TeX Gyre Heros Makie', `url(http://127.0.0.1:${port}/fonts/TeXGyreHerosMakie-Regular.otf)`); await ff.load(); document.fonts.add(ff);
    const { addCanvasLabel } = await import(`http://127.0.0.1:${port}/label_sprites.mjs`);
    const L = [['inside the sphere', [0, 0, 0], [0, 0], 22, '#000'], ['beyond the edge', [0.95, 0, 0.35], [-1, 0], 22, '#000'], ['above', [0, 0, 1.5], [0, 0], 20, '#00f']];
    window.__sprites = L.map(([text, anchor, align, fontsize, color]) => addCanvasLabel(window.WGL, { text, anchor, align, fontsize, color }));
  }, { port });
  await p.waitForTimeout(1500);
}
const rect = await p.evaluate(() => { const r = document.querySelector('canvas').getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; });
await p.screenshot({ path: `${outPrefix}_${variant}_view1.png`, clip: rect });
const png = await p.evaluate(() => document.querySelector('canvas').toDataURL('image/png'));
fs.writeFileSync(`${outPrefix}_${variant}_view1_export.png`, Buffer.from(png.split(',')[1], 'base64'));
// orbit: move the camera in the browser (OrbitControls' own `change`: what a drag does when the page has no Julia session), 50 degrees about z, then up a little
await p.evaluate(() => {
  const sc = Object.values(window.WGL.scene_cache).find((s) => s.orbitcontrols), c = sc.orbitcontrols, cam = c.object;
  const a = 50 * Math.PI / 180, { x, y, z } = cam.position;
  cam.position.set(x * Math.cos(a) - y * Math.sin(a), x * Math.sin(a) + y * Math.cos(a), z * 0.6);
  cam.lookAt(c.target); c.update(); c.dispatchEvent({ type: 'change' });
});
await p.waitForTimeout(2500);
await p.screenshot({ path: `${outPrefix}_${variant}_view2.png`, clip: rect });
console.log(variant, 'shots', JSON.stringify(rect));
await b.close(); s.close();
