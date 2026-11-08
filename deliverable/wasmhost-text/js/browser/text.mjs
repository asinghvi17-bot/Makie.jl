// The browser's text backend for WasmHost (`common/text.mjs`): glyph coverage bitmaps and metrics from Canvas2D.
// Fonts are the page's: register them with `FontFace` (or @font-face) before the module asks; `ensure` loads a
// registered face on first use, which is why a glyph job is asynchronous (the module parks on a julia_io handle).
//
//   const text = makeBrowserText({ events, memory: () => inst.exports.memory });
//   imports.wasm_host = { ...http.imports.wasm_host, ...text.imports.wasm_host };
//
// Canvas2D facts this relies on (Chromium 158, measured against FreeType on TeX Gyre Heros Makie):
//  - `measureText().width` at 1000 or 2000 px is the font's unhinted advance, exactly (0.24/1000 em off at 2048 px, no good above 8192 px);
//  - `actualBoundingBox*` is NOT tight (it is 0.5-1.5 % of the em larger per side), so the ink box comes from the pixels;
//  - `fontBoundingBoxAscent/Descent` are the hhea ascender/descender; the line gap is only visible as the CSS
//    `line-height: normal` height of a DOM element (the `height` of FreeType's face).
import { makeJobs } from '../common/jobs.mjs';
import { makeTextImports } from '../common/text.mjs';

// (4000 px: an exact multiple of 1000-unit em fonts like the bundled CFFs, so Chromium's integer-pixel advances are exact there; 1/8000 em worst case for others. Not above 8192: Chromium misreports beyond it)
const ADVANCE_PX = 4000;

export function browserBackend({ createCanvas = (w, h) => new OffscreenCanvas(w, h), doc = globalThis.document } = {}) {
  const measureCtx = createCanvas(8, 8).getContext('2d');
  const cssFont = (style, family, px) => `${style ? style + ' ' : ''}${px}px "${family}"`;
  const loaded = new Set();
  async function ensure(style, family) {
    const key = `${style}|${family}`;
    if (loaded.has(key)) return;
    const f = cssFont(style, family, 16);
    if (doc?.fonts && !doc.fonts.check(f)) await doc.fonts.load(f);
    loaded.add(key);
  }
  const glyphs = new Map();
  return {
    async font({ style, family }) {
      await ensure(style, family);
      measureCtx.font = cssFont(style, family, 1000); measureCtx.textBaseline = 'alphabetic';
      const m = measureCtx.measureText('x');
      let height = (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent) / 1000;
      if (doc) {   // (ascent + descent + line gap: what CSS calls `normal`)
        const el = doc.createElement('span');
        el.style.cssText = `position:absolute;visibility:hidden;white-space:pre;line-height:normal;font:${cssFont(style, family, 1000)}`;
        el.textContent = 'x'; doc.body.appendChild(el);
        height = el.getBoundingClientRect().height / 1000; el.remove();
      }
      return { ascender: m.fontBoundingBoxAscent / 1000, descender: -m.fontBoundingBoxDescent / 1000, height };
    },
    async glyph({ style, family, cp, px }) {
      const key = `${style}|${family}|${cp}|${px}`;
      let g = glyphs.get(key);
      if (g) return g;
      await ensure(style, family);
      const ch = String.fromCodePoint(cp), font = cssFont(style, family, px);
      measureCtx.font = cssFont(style, family, ADVANCE_PX); measureCtx.textBaseline = 'alphabetic';
      const advance = measureCtx.measureText(ch).width / ADVANCE_PX;
      measureCtx.font = font;
      const m = measureCtx.measureText(ch);
      // a canvas that holds the glyph with a margin (the reported box is loose, so it is only a size)
      const padL = Math.ceil(Math.max(0, m.actualBoundingBoxLeft)) + 2, padT = Math.ceil(Math.max(0, m.actualBoundingBoxAscent)) + 2;
      const W = padL + Math.ceil(Math.max(0, m.actualBoundingBoxRight)) + 3, H = padT + Math.ceil(Math.max(0, m.actualBoundingBoxDescent)) + 3;
      const ctx = createCanvas(Math.max(W, 1), Math.max(H, 1)).getContext('2d', { willReadFrequently: true });
      ctx.font = font; ctx.textBaseline = 'alphabetic'; ctx.fillStyle = '#fff';
      ctx.fillText(ch, padL, padT);
      const d = ctx.getImageData(0, 0, W, H).data;
      let x0 = W, x1 = -1, y0 = H, y1 = -1;
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (d[(y * W + x) * 4 + 3] > 0) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
      if (x1 < 0) g = { w: 0, h: 0, left: 0, top: 0, bitmap: new Uint8Array(0), advance, inkLeft: 0, inkTop: 0, inkW: 0, inkH: 0 };
      else {
        const w = x1 - x0 + 1, h = y1 - y0 + 1, bitmap = new Uint8Array(w * h);
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) bitmap[y * w + x] = d[((y + y0) * W + x + x0) * 4 + 3];
        const left = x0 - padL, top = padT - y0;     // FreeType's bitmap_left / bitmap_top
        g = { w, h, left, top, bitmap, advance, inkLeft: left / px, inkTop: top / px, inkW: w / px, inkH: h / px };
      }
      glyphs.set(key, g);
      return g;
    },
  };
}

export function makeBrowserText({ events, memory, backend = browserBackend(), check, stats = {} }) {
  const jobs = makeJobs(events, stats);
  return { ...makeTextImports({ jobs, memory, backend, check, stats }), backend };
}
