// window.runModule({ wasm, text, fonts }) -> { stdout, stderr, rc, ms, stats }: runs a text probe's `main` on
// @bjorn3/browser_wasi_shim with the browser text backend (WasmHost js/browser/text.mjs). `fonts`: [{ family, url, style, weight }],
// registered with FontFace but NOT loaded: the first glyph job loads the face, which is the asynchronous case the module parks for.
import { WASI, File, OpenFile, PreopenDirectory, ConsoleStdout } from '/shim/index.js';
import { makeShimJuliaIOPaths, jspiGap } from '/wh/js/browser/index.mjs';
import { makeBrowserText } from '/wh/js/browser/text.mjs';
import { makeJuliaIOEvents } from '/wcg/js/julia_io.mjs';

window.runModule = async ({ wasm, text, fonts = [] }) => {
  const out = { userAgent: navigator.userAgent, stdout: [], stderr: [], jspiGap: jspiGap() };
  if (out.jspiGap) return out;
  for (const f of fonts) document.fonts.add(new FontFace(f.family, `url(${f.url})`, { style: f.style ?? 'normal', weight: f.weight ?? '400' }));
  const mod = await WebAssembly.compileStreaming(fetch(wasm));
  out.imports = [...new Set(WebAssembly.Module.imports(mod).map((i) => i.module))];
  const root = new PreopenDirectory('/work', new Map());
  const wasi = new WASI(['prog'], [`TEXT=${text}`, 'PWD=/work'], [
    new OpenFile(new File([])), ConsoleStdout.lineBuffered((l) => out.stdout.push(l)), ConsoleStdout.lineBuffered((l) => out.stderr.push(l)), root], { debug: false });
  const events = makeJuliaIOEvents();
  const paths = makeShimJuliaIOPaths(wasi);
  let memory = null;
  const stats = {};
  const tx = makeBrowserText({ events, memory: () => memory, stats });
  const inst = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: wasi.wasiImport,
    julia_io: { ...paths.imports, ...events.imports },
    ...tx.imports,
  });
  memory = inst.exports.memory; events.bindMemory(memory); paths.bindMemory(memory);
  wasi.initialize(inst);
  const t0 = performance.now();
  out.rc = String(await WebAssembly.promising(inst.exports.main)());
  out.ms = performance.now() - t0;
  out.stats = stats;
  return out;
};
window.pageReady = true;
