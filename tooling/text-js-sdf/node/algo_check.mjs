// Same bitmap in, JS vs Makie: FreeType's 320 px bitmaps (sdf_ref.json) through common/sdf.mjs, compared with Makie's own
// `sdistancefield` tile for the same bitmap (isolates the algorithm: no rasterizer difference), and the JS time per glyph.
// node algo_check.mjs sdf_ref.json path/to/WasmHost/js/common/sdf.mjs [out.json]
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const ref = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const { sdfTile } = await import(pathToFileURL(process.argv[3]).href);
const b64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));
const f32 = (s) => { const b = b64(s); return new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4); };

const rows = [], times = [];
for (const g of ref.glyphs) {
  const bmp = b64(g.bmp), w = g.bw, h = g.bh;
  sdfTile(bmp, w, h, ref.downsample, ref.pad);          // (warm-up for the first ones)
}
for (const g of ref.glyphs) {
  const bmp = b64(g.bmp), w = g.bw, h = g.bh, want = f32(g.sdf);
  const reps = 5; let best = Infinity, tile;
  for (let r = 0; r < reps; r++) { const t0 = performance.now(); tile = sdfTile(bmp, w, h, ref.downsample, ref.pad); best = Math.min(best, performance.now() - t0); }
  times.push(best);
  let maxd = 0, sum = 0, maxrel = 0;
  const same = tile.tw === g.tw && tile.th === g.th;
  if (same) for (let i = 0; i < want.length; i++) { const d = Math.abs(tile.data[i] - want[i]); sum += d; if (d > maxd) maxd = d; }
  rows.push({ c: g.c, bw: w, bh: h, tw: g.tw, th: g.th, dims_equal: same, max_abs: same ? maxd : null, mean_abs: same ? sum / want.length : null, ms: best });
}
const ok = rows.filter(r => r.dims_equal);
const mx = Math.max(...ok.map(r => r.max_abs)), mean = ok.reduce((a, r) => a + r.mean_abs, 0) / ok.length;
times.sort((a, b) => a - b);
const res = { n: rows.length, dims_equal: ok.length, max_abs: mx, mean_abs_mean: mean, ms_mean: times.reduce((a, b) => a + b) / times.length, ms_median: times[times.length >> 1], ms_max: times[times.length - 1],
  node: process.version, native_sdf_ms: ref.native_sdf_ms, rows };
console.log(JSON.stringify({ ...res, rows: undefined }, null, 1));
if (process.argv[4]) fs.writeFileSync(process.argv[4], JSON.stringify(res));
