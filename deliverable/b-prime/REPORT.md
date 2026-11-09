# Route B′ (SDF computed in JS) and Route C′ (canvas-texture sprites): results

Base: branch `trim/text-browser` @020400c1 (routes B and C; see `../REPORT.md`). This work is committed on the task branch
`factory/89f6bd12-ac24-4759-989e-a06715a1e717` (the brief's name `trim/text-js-sdf`; see "Branch" below).
Setup as in `../REPORT.md` section "Setup": Julia 1.13.2 (the official 1.13.2 build on this machine; no separate Dyad build was installed),
Makie = this tree (the merge of `trim/axis-typed-access` and `trim/computepipeline-static-dispatch`), WasmCodegen `feat/task-park-host-wait` 467d91e,
WasmCompat 8df2164, WasmHost 5cb54e3 + `0001` + `0002` patches. Strict builds (`verify=:error`, `host=:wasi`, `trim=:safe`, `shell_first_mutables=true`),
`optimize=nothing` (no wasm-opt). Headless Chromium 158 (Playwright, SwiftShader), Node 26.10. Stacked depot (task depot : `~/.julia` : bundled), precompile not throttled
(`JULIA_NUM_PRECOMPILE_TASKS=12`).

## 1. What was built

- `deliverable/wasmhost-text/0002-wasmhost-text-sdf-job.patch` (on top of `0001`; also the files under `wasmhost-text/js/common/`):
  - `sdf.mjs`: vendors `edt`/`edt1d` of `@mapbox/tiny-sdf` 2.3.0 (BSD-2-Clause; full license in `LICENSE-tiny-sdf.txt` and in the file header) and `sdfTile(bitmap, w, h, downsample, pad)`,
    which reproduces Makie's `sdistancefield` (`Makie/src/utilities/texture_atlas.jl:331-353`): binary in/out at coverage > 127.5, padding `pad*downsample`, exact squared EDT both ways,
    `sqrt(outer) - sqrt(inner)`, 5x5 block mean divided by 5; a bitmap without inside pixels gives `prod(size)/downsample` like SignedDistanceFields.jl does (this is what a space gets).
  - `text.mjs`: new request kind `sdf` (codepoint, px, downsample, pad) -> `[1, status, tw, th, left, top, advance, ink...]` + `tw*th` float32 (x fastest = a Julia `Matrix{Float32}`);
    `runTextRequest(backend, requestText, stats)` exported; per-kind host times in `stats.ms`. No other third-party JS; nothing for plotting.
- `tooling/text-js-sdf/probes/browser_glyphs_sdf.jl`: `browser_glyphs.jl` with `render_glyph` taking the host's finished tile (`glyph_sdf`/`parse_sdf`) and going straight to Makie's packer and atlas write;
  `p_Bsdf_text.jl` (the text probe with statistics for every distinct glyph), `p_Bjulia_text.jl` (route B with the same statistics), `p_Bsdf_axis.jl` (Axis with tick labels).
- `tooling/text-js-sdf/hosted/`: the same Julia source evaluated natively with the host answered from a table that Chromium fills with the real adapter code (see 3.5).
- `tooling/text-js-sdf/{native,node,browser}/`: the SDF reference and comparison scripts. `tooling/text-js-sdf/cprime/`: the C′ prototype.

## 2. Measurements

### 2.1 SDF tile against native Makie (`sdf/`)
115 glyphs of TeX Gyre Heros Makie (ASCII 32-126 and 20 more), 320 px bitmap, downsample 5, pad 12, i.e. Makie's atlas settings.
- **Same bitmap** (`sdf/algo_check_same_bitmap.json`; FreeType's bitmaps through `sdfTile`, against `Makie.sdistancefield`): 115 of 115 tiles the same size, **max |diff| 0, mean |diff| 0** (bit-identical Float32).
- **Browser raster** (`sdf/sdf_cmp_chromium.json`; Canvas2D at 320 px in Chromium 158, then `sdfTile`, against the tile of FreeType's bitmap of the same glyph): 103 of 115 tiles the same size
  (the 12 others are 1 tile pixel larger or smaller in one direction: `# ( ; < > C G M O S w •`, the Canvas2D bounding box differs by 1 px). On the 103: **max 0.385, mean 0.0185** (pooled over pixels 0.021; median tile max 0.185, p95 0.240; worst `Q 5 @ ? Ω`).
  On the 93 glyphs with identical bitmap size: max 0.24, mean 0.0116. After Float16 rounding (the atlas type): max 0.385, mean 0.0185. Unit: tile pixels (the 64 px em).
- Native Makie for the same glyphs (`sdf_ref.json.gz`, `native/sdf_ref.jl`): `renderface` 0.2 ms, `sdistancefield` 34.4 ms (115 glyphs).

### 2.2 Time per glyph
| | native Julia | compiled module (B) | JS SDF, Node 26 (FreeType bitmaps) | JS SDF, Chromium 158 | whole B′ module |
|---|---|---|---|---|---|
| SDF step | 34.4 ms | ~700 ms | 3.4 ms mean, 3.3 median, 8.1 max (best of 5, 115 glyphs) | 3.2 ms best-of-5 mean, 3.7 first call (page); 5.4 (36 glyphs), 5.8 (90 glyphs) inside module runs | |
| raster 320 px | 0.2 ms (FreeType) | | | 0.64 ms mean (115 glyphs) | |
| per new glyph, whole module | | 739 ms (36 glyphs, 26.6 s, Chromium); Node mock 542 ms (15 glyphs, 8.1 s) | | | Chromium: 15 glyphs 0.41 s, 36 glyphs 0.55 s, 90 glyphs 0.97 s (slope 7.6 ms; ~4.2 ms/glyph is the module's own work); Node mock 15 glyphs 0.52 s |

(Chromium B run of the first report: 16-20 s for 15 glyphs; B′: 0.41 s.) Raw: `wasm-runs/*.json|err`.
The two Node mock outputs (B and B′, same bitmaps) are byte-identical, i.e. the in-module Julia SDF and the JS SDF give the same atlas.

### 2.3 Wasm size (`builds/`)
| module | bytes | gzip -9 | build | peak RSS | verifier |
|---|---|---|---|---|---|
| B′ `p_Bsdf_text` | 4,741,203 | 975,218 | 255 s (compile 219.9 s) | 1,878,260 KB | clean |
| B `p_Bjulia_text` | 4,786,737 | 997,213 | 304 s (compile 267.0 s) | 1,853,880 KB | clean |
| delta | **-45,534 (-0.95 %)** | **-21,995** | | | |
Unoptimized. The atlas of both is the empty 1024^2 one the first probe used (no 8 MiB Float16 image). (The capmap prerendered-atlas module, a different program, is 10.1 MB / 1.9 MB gzip.)

### 2.4 `text!` scene, strict, run in Chromium (`wasm-runs/Bsdf.chromium.*`)
`text!` built with "hello", set at run time to `Wasm: ünï 42 ΩΣ ≈ ∞`: rc 0, 31 host jobs (font 1, extent 15, sdf 15), 405 ms. Against native (`Bsdf.native.txt`): all 19 glyph origins/advances identical (max diff 0.000), block bbox identical,
font ascender/descender/height 947/-218/1165 identical, ink boxes within 0.005 em. The 94-glyph ASCII run and the 40-glyph run (`n94`, `n40`) are in the same folder.

### 2.5 Image difference to native (`images/`)
The Wasm module's output cannot be displayed by WGLMakie's JS (no JS<->wasm session bridge, capmap blocker 4). So: the same Julia source (`browser_glyphs_sdf.jl`, transformed only by
dropping `@overlay WASM`, the `getproperty(::FTFont)` method and replacing `host_job` by a table lookup; `hosted/hosted_bsdf.jl`) runs natively inside WGLMakie/Bonito; the host's answers are produced in headless Chromium by the real
WasmHost adapter code (`runTextRequest` + `browserBackend` + `sdfTile`) in a loop (Julia lists the requests it lacks, Chromium answers, repeat; `hosted/*.tsv` are the tables); the page is screenshotted in headless Chromium.
Check that the hosted run is the module: the probe `p_Bsdf_text.jl` run hosted prints exactly what the compiled module prints in Chromium (`wasm-runs/Bsdf.hosted.txt` vs `Bsdf.chromium.txt`; only the `[main returned 0]` line of `native.jl` differs).
Noise floor: native screenshot twice = bit-identical (diff 0).
| scene | size | mean abs gray diff / 255 | pixels > 32 | max | pixels with ink in either image: mean diff |
|---|---|---|---|---|---|
| text scene (7 `text!`: 4 sizes, bold, italic, rotated, accents, Greek) | 600x260 | 0.287 | 24 of 156,000 | 66 | 3.9 |
| Axis (title, labels, tick labels; 35 distinct glyphs) | 600x400 | 0.042 | 3 of 240,000 | 45 | 0.57 |
`images/shot_{text,axis}_{native,bsdf,sheet}.png`; sheet = native | B′ | difference (x4, inverted).

### 2.6 Axis strict compile (`builds/Bsdf_axis.*`)
`p_Bsdf_axis.jl` (capmap's `p_A_axis.jl` with the host's text instead of the prerendered atlas) runs natively; the strict compile **fails: 437 verifier errors** (capmap: 439 with the atlas), 148 s, 2,319,756 KB.
0 of 437 mention `BrowserGlyphsSDF` or `texture_atlas.jl`; by first Makie/ComputePipeline frame: text.jl 117 (`layout_text` over `input_text::Vector{Any}` :547, :155, :566), ComputePipeline.jl 108, conversions.jl 100, WasmCompatObservablesExt 20, axis.jl 19, data_limits 16, ...
Text through the host is not what blocks the Axis. Full list: `builds/Bsdf_axis.wasm.errors.txt.gz`.

## 3. Route C′: canvas-texture sprites with depth test (`cprime/`)
Feasible, and a prototype is cheap, so it was built (`tooling/text-js-sdf/cprime/label_sprites.mjs`, about 60 lines): a label is drawn with Canvas2D into a `CanvasTexture`; a `PlaneGeometry` quad with a `ShaderMaterial` whose uniforms are the 3D scene's own
`scene.wgl_camera.projectionview` and `.resolution` (the objects OrbitControls updates; `scene.orbitcontrols` marks the 3D scene in `WGL.scene_cache`), anchored at the label's 3D point, sized in pixels, `depthTest: true`, `depthWrite: false`, `transparent: true`.
- LScene with an opaque sphere and three labels (`scene3d.jl`; native Makie `text!(markerspace = :pixel)` against sprites; both have the same default camera, the sprite variant gets invisible points at the label anchors so the data limits match):
  occlusion matches native: "inside the sphere" hidden, "beyond the edge" cut by the sphere, "above" visible. Mean abs gray diff 0.11 (view 1; 357 of 240,000 pixels above 32) and 0.08 (view 2, 237 pixels above 32), differences at glyph edges. `cprime/cp_sheet.png`: native view1, native view2, diffs; sprite view1, view2.
- Camera moved in the browser (OrbitControls `change`): the sprites follow with no Julia round trip.
- `canvas.toDataURL` export contains the sprites (identical to the screenshot, `cp_sprite_view1_export.png`), unlike the DOM overlay of C.
- Stroke: `strokeText` on the texture (supported in `addCanvasLabel`'s `stroke`, not exercised); rich text per-run colours: draw runs into the same canvas (not done).
- Limits: one depth per label (its anchor's; the same as Makie's pixel-space text); the texture is rasterized once at the page's device pixel ratio (data-space labels scaled by perspective blur; re-rasterize on zoom is needed); transparent objects are sorted by object, not by label depth; not in the picking pass; clip planes/overdraw need shader work; layout is the browser's, not Makie's; LaTeX/rich text still use glyphs.
Not done: sprites for Axis tick labels (they are 2D: C's DOM/Canvas2D layer is simpler there), interaction through Julia (`Camera3D`), several labels' sorting.

## 4. Conclusion
See capmap section 3 (`deliverable/capmap/index.html`, updated). B′ makes B usable: tiles equal Makie's up to the browser's raster (max 0.385 tile px), 8-11 ms per new glyph instead of 740 ms, a smaller module, strict compile clean, runtime text with never-seen glyphs works in Chromium.
It keeps B's limits: codepoint addressing (no MathTeXEngine/LaTeX), the browser's fallback instead of Makie's, JSPI for the parking design, Chromium only.

## 5. Peak RSS per step (`/usr/bin/time -f %M`)
| step | peak RSS |
|---|---|
| `Pkg.develop` + `Pkg.add` (resolve, 18.9 s) | 610,792 KB |
| `Pkg.precompile`, full (418 s, 12 tasks) | 4,534,756 KB |
| native FreeType reference `sdf_ref.jl` (x2) | 831,220 / 830,424 KB |
| native probes B / B′ | 1,196,532 / 1,194,140 KB |
| strict compile B′ / B / Axis (fails) | 1,878,260 / 1,853,880 / 2,319,756 KB |
| Node mock runs B′ / B | 294,356 / 295,172 KB |
| Node process driving Chromium (B′ n=15, 40, 94; B n=40); Chromium's own processes were not measured | 122,644 / 123,028 / 122,088; 122,744 KB |
| hosted renders (native + B′ passes, text / Axis, one script each) | 1,024,588 / 1,017,160 KB |
| load of Makie/WGLMakie (re-precompile, see below) | not recorded (about 2m40 and 2m55 wall) |
Not measured: `sdf_cmp`, `algo_check` (small Node/Chromium scripts), C′ runs, native hosted probe run.
One of my commands ran Julia without the `JULIA_DEPOT_PATH` trailing colon / `JULIA_NUM_PRECOMPILE_TASKS` setting, which made Makie and WGLMakie recompile twice (about 6 minutes); that is why two loads show as slow in my log, and it did not touch any result.

## 6. Not done, doubts
- wasm-opt was not run (as in B/C: it did not fit in 10-minute commands); sizes are of the unoptimized modules, only their delta is meaningful.
- Firefox/WebKit not run (as before). JSPI is needed for the parking design; a synchronous variant for pre-loaded fonts is described, not built.
- Julia is the official 1.13.2 build found on the machine (`julia --version` 1.13.2); no "Dyad" build was installed here. WasmCodegen ran.
- The Axis comparison is hosted-native, not a compiled module (the Axis does not compile strictly, section 2.6).
- The browser's raster differs from FreeType's by 1 px in the bounding box for 22 of 115 glyphs (a 1-tile-pixel size change of the tile for 12); this is the Canvas2D rasterizer, not the SDF.
- Hosted-native replaces FreeType process-wide (`glyph_index` is the codepoint) and does not apply the host's font-metric overlay (equal to FreeType's, section 2.4).

## Reproducing
Needs capmap's `common.jl`, `overrides.jl`, `native.jl`, `build.jl`, `text_overrides.jl` (private repo, `capmap-v1`) next to `probes/*.jl`; `text_common.jl` is in `tooling/text-browser/probes/`.
`julia --project=ENV build.jl p_Bsdf_text.jl out/Bsdf_text.wasm`; `node tooling/text-js-sdf/host/run_chromium.mjs out/Bsdf_text.wasm out.json "<text>"` (env as in its header) or `run_node.mjs` (mock);
`julia sdf_ref.jl sdf_ref.json`, `node node/algo_check.mjs sdf_ref.json WasmHost/js/common/sdf.mjs`, `node browser/run_sdf_cmp.mjs sdf_ref.json out.json`; `FIG=text|axis hosted/run_hosted.sh` and `hosted/compare_shots.py`; `VARIANT=native|sprite OUT=cp julia cprime/scene3d.jl`.

## Branch
Committed on the task branch `factory/89f6bd12-ac24-4759-989e-a06715a1e717`, on top of `trim/text-browser` @020400c1 (the brief asked for `trim/text-js-sdf`; the factory rules say to commit on the task branch only, so no branch of that name was created and nothing was pushed).
