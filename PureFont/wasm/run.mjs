// node run.mjs MODULE.wasm [time] — run the module's `main` on node:wasi, printing what it prints; with `time`, time new glyphs
import fs from 'node:fs';
import { WASI } from 'node:wasi';
const wasi = new WASI({ version: 'preview1', args: ['prog'], env: {}, returnOnExit: true });
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
wasi.initialize(inst);
const rc = inst.exports.main();
process.stdout.write(`\n[main returned ${rc}]\n`);
if (process.argv[3] === 'time') {
  // new glyphs: code points the font has that `main` did not use
  const n = inst.exports.ncp();
  const t0 = performance.now();
  inst.exports.glyph(inst.exports.nth_cp(0));
  const first = performance.now() - t0;
  const t1 = performance.now();
  for (let i = 1; i < n; i++) inst.exports.glyph(inst.exports.nth_cp(i));
  const dt = performance.now() - t1;
  process.stdout.write(`wasm: first new glyph ${first.toFixed(2)} ms; then ${(dt / (n - 1)).toFixed(3)} ms per new glyph (${n - 1} glyphs)\n`);
  const t2 = performance.now();
  for (let i = 1; i < n; i++) inst.exports.glyph(inst.exports.nth_cp(i));
  process.stdout.write(`wasm: ${((performance.now() - t2) / (n - 1)).toFixed(4)} ms per already-rendered glyph\n`);
  for (const name of ['bench_raster', 'bench_sdf']) {
    inst.exports[name](inst.exports.nth_cp(0));
    const tb = performance.now();
    for (let i = 1; i < n; i++) inst.exports[name](inst.exports.nth_cp(i));
    process.stdout.write(`wasm: ${name} ${((performance.now() - tb) / (n - 1)).toFixed(3)} ms per glyph\n`);
  }
  const t3 = performance.now();
  inst.exports.advance_sum(0x60);
  process.stdout.write(`wasm: ${(performance.now() - t3).toFixed(3)} ms for the metrics of 96 glyphs\n`);
}
