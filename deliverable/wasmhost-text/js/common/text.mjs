// Text host jobs for modules compiled by WasmCodegen: the glyphs and font metrics a browser (or a mock) provides
// where FreeType cannot run. Protocol `wasm-text 1`, over `wasm_host.text_start(req, req_len) -> handle` and
// `wasm_host.text_finish(handle, res, res_cap) -> len`, the same start/finish shape as `http_start`/`http_finish`:
// the job runs while the module's task waits for the julia_io handle (Runtime.Host.await_handle).
//
//   request  (UTF-8, one field per line):
//     "wasm-text 1"
//     "glyph" | "extent" | "font" | "measure"
//     style  ("" | "bold" | "italic" | "italic bold"; the CSS font-style/weight words)
//     family (the CSS family name, as registered with the page's FontFace)
//     glyph/extent only:  codepoint (decimal), pixel size (decimal)
//     measure only:       pixel size (decimal), then the string (\n and \\ escaped: one line)
//
//   response (binary, little-endian; all i32; "em6" = em fractions times 1e6, rounded):
//     font:   [1, status, ascender_em6, descender_em6 (negative), height_em6]
//     glyph:  [1, status, w, h, left_px, top_px, advance_em6, ink_left_em6, ink_top_em6, ink_w_em6, ink_h_em6] then w*h bytes
//             of coverage, row-major, top row first (FreeType's bitmap order: row 0 is the glyph's top), `left_px`/`top_px`
//             are FreeType's bitmap_left/bitmap_top (pixels from the origin to the bitmap's left edge / top edge, y up).
//     extent: the same without the bytes (w and h still tell the bitmap's size)
//     measure: [1, status, width in 1/1000 px]  (what `measureText` says of the string, kerning and ligatures included)
//     status 0 = ok, else a WASI errno; on a failure the rest is zeros and `errmsg` text follows the header.

export const PROTOCOL = 'wasm-text 1';
const enc = new TextEncoder();

export function parseTextRequest(text) {
  const f = text.split('\n');
  if (f[0] !== PROTOCOL) throw new Error(`wasm-text: protocol ${f[0]}`);
  const kind = f[1];
  if (kind === 'font') return { kind, style: f[2], family: f[3] };
  if (kind === 'measure') return { kind, style: f[2], family: f[3], px: Number(f[4]), text: f.slice(5).join('\n').replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c)) };
  if (kind === 'glyph' || kind === 'extent') return { kind, style: f[2], family: f[3], cp: Number(f[4]), px: Number(f[5]) };
  throw new Error(`wasm-text: request ${kind}`);
}

const em6 = (x) => Math.round(x * 1e6);

export function formatFont(r) {
  const out = new Uint8Array(5 * 4); const dv = new DataView(out.buffer);
  [1, 0, em6(r.ascender), em6(r.descender), em6(r.height)].forEach((v, i) => dv.setInt32(i * 4, v, true));
  return out;
}

export function formatMeasure(width) {
  const out = new Uint8Array(3 * 4); const dv = new DataView(out.buffer);
  [1, 0, Math.round(width * 1000)].forEach((v, i) => dv.setInt32(i * 4, v, true));
  return out;
}

export function formatGlyph(r, withBitmap) {
  const n = withBitmap ? r.w * r.h : 0;
  const out = new Uint8Array(11 * 4 + n); const dv = new DataView(out.buffer);
  [1, 0, r.w, r.h, r.left, r.top, em6(r.advance), em6(r.inkLeft), em6(r.inkTop), em6(r.inkW), em6(r.inkH)].forEach((v, i) => dv.setInt32(i * 4, v, true));
  if (n) out.set(r.bitmap, 44);
  return out;
}

export function formatError(errno, message) {
  const m = enc.encode(String(message));
  const out = new Uint8Array(11 * 4 + m.length); const dv = new DataView(out.buffer);
  dv.setInt32(0, 1, true); dv.setInt32(4, errno, true);
  out.set(m, 44);
  return out;
}

// The adapter: `backend` has `async font({style, family}) -> {ascender, descender, height}` (em fractions) and
// `async glyph({style, family, cp, px}) -> {w, h, left, top, bitmap, advance, inkLeft, inkTop, inkW, inkH}`,
// `async measure({style, family, px, text}) -> width in px`.
// `jobs` is common/jobs.mjs's `makeJobs(events, stats)`; `memory()` the module's memory.
export function makeTextImports({ jobs, memory, backend, check = () => {}, stats = {} }) {
  stats.textJobs ??= 0; stats.glyphJobs ??= 0;
  const text = (off, len) => new TextDecoder().decode(new Uint8Array(memory().buffer, off >>> 0, len));
  async function run(reqText) {
    try {
      const req = parseTextRequest(reqText);
      stats.textJobs++;
      if (req.kind === 'font') return formatFont(await backend.font(req));
      if (req.kind === 'measure') return formatMeasure(await backend.measure(req));
      stats.glyphJobs++;
      return formatGlyph(await backend.glyph(req), req.kind === 'glyph');
    } catch (err) {
      return formatError(5 /* EIO */, err?.message ?? err);
    }
  }
  function text_start(reqOff, reqLen) {
    check();
    const reqText = text(reqOff, reqLen);
    return jobs.start(() => run(reqText));
  }
  function text_finish(h, resOff, resCap) {
    check();
    const bytes = jobs.result(h);
    if (bytes === undefined) return 0;
    if (bytes.length > resCap) return -bytes.length;
    new Uint8Array(memory().buffer, resOff >>> 0, bytes.length).set(bytes);   // (a fresh view: memory may have grown)
    return bytes.length;
  }
  return { imports: { wasm_host: { text_start, text_finish } }, stats };
}
