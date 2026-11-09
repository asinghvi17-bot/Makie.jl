// node --experimental-wasm-jspi? run_node.mjs MODULE.wasm WASMCODEGEN_DIR WASMHOST_DIR [TEXT]
// Runs a text probe on node:wasi with the MOCK text backend (WasmHost js/node/text_mock.mjs: synthetic glyphs, no fonts).
import fs from 'node:fs';
import path from 'node:path';
import { WASI } from 'node:wasi';

const [wasmPath, wcg, wh, text = 'Wasm: ünï 42 ΩΣ ≈ ∞'] = process.argv.slice(2);
const { makeJuliaIOEvents, makeJuliaIOPaths } = await import(path.join(path.resolve(wcg), 'js', 'julia_io.mjs'));
const { makeMockText } = await import(path.join(path.resolve(wh), 'js', 'node', 'text_mock.mjs'));
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
const libs = [...new Set(WebAssembly.Module.imports(mod).map((i) => i.module))];
console.error('imports:', libs.join(', '));
const wasi = new WASI({ version: 'preview1', args: ['prog'], env: { TEXT: text }, returnOnExit: true });
const events = makeJuliaIOEvents();
const paths = makeJuliaIOPaths({ preopens: [] });
let memory = null;
const stats = {};
const tx = makeMockText({ events, memory: () => memory, stats });
// (TRACE_HOST=1: log the calls of julia_io and wasm_host; the suspending ones pass through)
const trace = process.env.TRACE_HOST ? (lib, imps) => Object.fromEntries(Object.entries(imps).map(([k, f]) => [k, typeof f !== 'function' ? f : (...a) => { const r = f(...a); console.error(`[${lib}.${k}]`, a.join(','), '->', r); return r; }])) : (lib, imps) => imps;
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  julia_io: trace('julia_io', { ...paths.imports, ...events.imports }),
  wasm_host: trace('wasm_host', tx.imports.wasm_host),
});
memory = inst.exports.memory; events.bindMemory(memory); paths.bindMemory(memory);
wasi.initialize(inst);
const rc = await WebAssembly.promising(inst.exports.main)();
process.stdout.write(`\n[main returned ${rc}]\n`);
console.error('host:', JSON.stringify(stats));
