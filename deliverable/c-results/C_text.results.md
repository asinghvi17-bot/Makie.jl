# C in Wasm (p_C_text.jl): results, transcribed from the console

The raw output files of this run (module, build log, Chromium JSON, overlay PNG) were in the task's TMPDIR, which was
reaped before they were copied here. What follows is what the commands printed.

- Strict compile (`verify=:error`, `host=:wasi`, `trim=:safe`, `optimize=nothing`, `host_extensions=[:julia_io]`,
  `import_libraries=["wasm_host"]`): `compiled in 496.1 s, 4662777 bytes`, `verifier: clean`; 1363 functions emitted, 0 unsupported
  constructs; `/usr/bin/time` max RSS 1,812,172 KB (574.7 s wall including the native prepare).
- Headless Chromium 158 (`TEXT="Wasm: ünï 42 ΩΣ ≈ ∞"`): `rc=0 505-528 ms`, host jobs `{"textJobs":2,"glyphJobs":0}` (one `font`, one `measure`).
  Printed `layout bbox 0.0 -8.72 387.0 46.6; blank glyphs 1` and one label
  `{"text":"Wasm: ünï 42 ΩΣ ≈ ∞","x":10.0,"y":131.28,"size":40.0,"color":[1,0,0,1],"angle":0.0,"family":"TeX Gyre Heros Makie","ascender":0.947,"descender":-0.218,"width":387.0}`.
- Native (FreeType) for the same string: bbox width 389.4 (browser: 387.0, i.e. Chromium's whole-string shaping with kerning is 0.6 % narrower).
- Node with the MOCK backend: width 418.0 (synthetic: 0.55 em per character), 0.58 s.
- Rendered as a DOM overlay (left) and a Canvas2D layer (right) from that label line, both showed the string in red at the same place
  (screenshot not kept).
