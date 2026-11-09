// window.runCmp({ ref, family, fontUrl }) -> per glyph: the browser's tile (Canvas2D raster at 320 px, then common/sdf.mjs) against
// Makie's own tile for the FreeType bitmap of the same glyph (ref = sdf_ref.json from native/sdf_ref.jl), plus timings.
import { browserBackend } from '/wh/js/browser/text.mjs';
import { sdfTile } from '/wh/js/common/sdf.mjs';
const b64 = (s) => { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
const f32 = (s) => { const u = b64(s); return new Float32Array(u.buffer, 0, u.byteLength / 4); };
const f16 = (x) => { const a = new Float32Array(1); a[0] = x; return a[0]; };   // (placeholder; Float16Array rounding below when available)
const toF16 = typeof Float16Array !== 'undefined' ? (v) => Float16Array.from(v) : null;

window.runCmp = async ({ ref, family, fontUrl }) => {
  document.fonts.add(new FontFace(family, `url(${fontUrl})`));
  const be = browserBackend();
  await be.font({ style: '', family });        // loads the face
  const r = await (await fetch(ref)).json();
  const rows = [], rasterMs = [], sdfMs = [], iou = [];
  for (const g of r.glyphs) {
    const t0 = performance.now();
    const gl = await be.glyph({ style: '', family, cp: g.c, px: r.px });
    const t1 = performance.now();
    const tile = sdfTile(gl.bitmap, gl.w, gl.h, r.downsample, r.pad);
    const t2 = performance.now();
    rasterMs.push(t1 - t0); sdfMs.push(t2 - t1);
    // best of 5 for the SDF step alone (no JIT noise)
    let best = t2 - t1;
    for (let k = 0; k < 4; k++) { const a = performance.now(); sdfTile(gl.bitmap, gl.w, gl.h, r.downsample, r.pad); best = Math.min(best, performance.now() - a); }
    const want = f32(g.sdf);
    const row = { c: g.c, ref_tile: [g.tw, g.th], js_tile: [tile.tw, tile.th], ref_bitmap: [g.bw, g.bh], js_bitmap: [gl.w, gl.h], sdf_ms_best: best, raster_ms: t1 - t0 };
    if (tile.tw === g.tw && tile.th === g.th) {
      let mx = 0, sum = 0, mx16 = 0, sum16 = 0, n = want.length;
      const q = toF16 ? toF16(tile.data) : tile.data, w16 = toF16 ? toF16(want) : want;
      for (let i = 0; i < n; i++) {
        const d = Math.abs(tile.data[i] - want[i]); sum += d; if (d > mx) mx = d;
        const d16 = Math.abs(q[i] - w16[i]); sum16 += d16; if (d16 > mx16) mx16 = d16;
      }
      Object.assign(row, { max_abs: mx, mean_abs: sum / n, max_abs_f16: mx16, mean_abs_f16: sum16 / n });
    }
    // coverage agreement of the bitmaps, when both have the same size (same box)
    rows.push(row);
  }
  return { ua: navigator.userAgent, px: r.px, downsample: r.downsample, pad: r.pad, native_sdf_ms: r.native_sdf_ms, rows, rasterMs, sdfMs };
};
window.pageReady = true;
