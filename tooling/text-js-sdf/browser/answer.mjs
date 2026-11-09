// window.answer({ requests: [text...], fonts: [{family, url, style, weight}] }) -> [Uint8 response as base64...]
// The real WasmHost adapter code answers: `runTextRequest` with the browser backend (Canvas2D raster, fonts, `sdfTile`).
import { browserBackend } from '/wh/js/browser/text.mjs';
import { runTextRequest } from '/wh/js/common/text.mjs';
const b64 = (u) => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };
window.answer = async ({ requests, fonts }) => {
  for (const f of fonts) document.fonts.add(new FontFace(f.family, `url(${f.url})`, { style: f.style ?? 'normal', weight: f.weight ?? '400' }));
  const be = browserBackend(), stats = {};
  const out = [];
  for (const r of requests) out.push(b64(await runTextRequest(be, r, stats)));
  return { out, stats };
};
window.pageReady = true;
