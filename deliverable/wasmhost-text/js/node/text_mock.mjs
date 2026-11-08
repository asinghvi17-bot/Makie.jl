// A MOCK text backend for Node (no Canvas2D, no fonts): deterministic synthetic glyphs, only to exercise the module's
// host calls, protocol and SDF path in `node` runs. Its glyphs are filled ellipses whose size depends on the codepoint;
// it does not measure any font. (A Node run with a real rasterizer would use e.g. node-canvas or skia-canvas as `createCanvas`
// of browser/text.mjs; not done here.)
import { makeJobs } from '../common/jobs.mjs';
import { makeTextImports } from '../common/text.mjs';

export function mockBackend() {
  return {
    async font() { await null; return { ascender: 0.947, descender: -0.218, height: 1.165 }; },
    async measure({ px, text }) { await null; return [...text].length * 0.55 * px; },
    async glyph({ cp, px }) {
      await null;   // (asynchronous like a font load: the module parks)
      const advance = 0.45 + (cp % 7) * 0.05;
      if (cp === 32 || cp === 10) return { w: 0, h: 0, left: 0, top: 0, bitmap: new Uint8Array(0), advance, inkLeft: 0, inkTop: 0, inkW: 0, inkH: 0 };
      const w = Math.round(px * (0.3 + (cp % 5) * 0.05)), h = Math.round(px * (0.5 + (cp % 3) * 0.1)), left = Math.round(px * 0.05), top = h;
      const bitmap = new Uint8Array(w * h);
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const dx = (x + 0.5) / w * 2 - 1, dy = (y + 0.5) / h * 2 - 1;
        bitmap[y * w + x] = dx * dx + dy * dy <= 1 ? 255 : 0;
      }
      return { w, h, left, top, bitmap, advance, inkLeft: left / px, inkTop: top / px, inkW: w / px, inkH: h / px };
    },
  };
}

export function makeMockText({ events, memory, check, stats = {} }) {
  const jobs = makeJobs(events, stats);
  return { ...makeTextImports({ jobs, memory, backend: mockBackend(), check, stats }) };
}
