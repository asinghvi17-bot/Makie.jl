# Makie 0.25 text in Wasm: browser rasterizer (B) and DOM/Canvas text (C)

Setup: Julia 1.13.2; Makie `trim/axis-typed-access` e2f01244 merged with `trim/computepipeline-static-dispatch` 37cb4114 (merge commit on
this branch); WasmCodegen `feat/task-park-host-wait` 467d91ed; WasmHost `feat/concurrent-fetch` 5cb54e32; WasmCompat `feat/observables-ext`
8df2164f. Compiles: strict (`verify=:error`, `host=:wasi`, `trim=:safe`, `shell_first_mutables=true`), one at a time,
with `optimize=nothing` (no wasm-opt: it did not fit in the 10-minute command limit on a host at load average 60-100).
Browser: headless Chromium 158 (Playwright, SwiftShader WebGL, JSPI on). Node 26 for the mock runs.
Not run: Firefox (Playwright's build fails to start in this sandbox: user-namespace `ENOSPC`), WebKit (missing host libraries).

## 1. Where the text pipeline needs font data

Permalinks are at Makie e2f01244 (`M`) and FreeTypeAbstraction v0.10.8 = 5ac9b3ff (`F`).
`M` = https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53 ,
`F` = https://github.com/JuliaGraphics/FreeTypeAbstraction.jl/blob/5ac9b3ffc5f90f5b77c4f59a5f94c73b80a567f2 .

| # | Stage | Where | Needs | C (metrics only)? | B (pixels)? |
|---|---|---|---|---|---|
| 1 | Glyph lookup: char -> glyph index, font fallback | [`find_font_for_char` M/Makie/src/utilities/texture_atlas.jl#L239-L250](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L239-L250), [`glyph_index!` #L252-L258](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L252-L258), [`layout_string` per-char font + index text_layouting.jl#L113-L122, #L187](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/layouting/text_layouting.jl#L113-L122); FreeType: [`glyph_index` F/src/types.jl#L232-L234](https://github.com/JuliaGraphics/FreeTypeAbstraction.jl/blob/5ac9b3ffc5f90f5b77c4f59a5f94c73b80a567f2/src/types.jl#L232-L234) | a cmap lookup (and "does this font have it" for fallback) | yes: C needs no glyph ids at all, the browser shapes the string and falls back by itself | yes, but Canvas2D draws a *codepoint*, not a glyph id (see 6) |
| 2 | Layout metrics and extents: advance, ink box, ascender/descender, line height | [`GlyphExtent` M/Makie/src/types.jl#L403-L431](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/types.jl#L403-L431), [`layout_string` text_layouting.jl#L98-L194](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/layouting/text_layouting.jl#L98-L194) (hadvance L40, `font.height/units_per_EM` L119, ascender/descender L164-177); FreeType: [`get_extent` F/src/types.jl#L219-L252](https://github.com/JuliaGraphics/FreeTypeAbstraction.jl/blob/5ac9b3ffc5f90f5b77c4f59a5f94c73b80a567f2/src/types.jl#L219-L252) (`FT_LOAD_NO_SCALE`, em-normalized) | numbers only | **yes: metrics suffice** | B needs the same numbers (from `measureText`) |
| 3 | String bounding boxes (drive Axis protrusions, Legend, Colorbar, tick-label sizes) | [`raw_glyph_boundingboxes` M/Makie/src/basic_recipes/text.jl#L836-L840](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L836-L840), [`raw/fast/string_boundingboxes` #L916-L1035](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L916-L1035), users: [lineaxis.jl#L407](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/makielayout/lineaxis.jl#L407), [axis.jl#L455, #L484](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/makielayout/blocks/axis.jl#L484) | numbers only, **but built from the per-glyph arrays, not from `TextLayout.bbox`** | yes, if a layout still returns glyph-array entries carrying the measured advance (found the hard way, see C) | same |
| 4 | Atlas insertion: rasterize a glyph into the SDF atlas | [`insert_glyph!` M/Makie/src/utilities/texture_atlas.jl#L277-L303](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L277-L303), [`render` (glyph) #L376-L407](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L376-L407) calls FreeType `renderface` [F/src/rendering.jl#L16-L23](https://github.com/JuliaGraphics/FreeTypeAbstraction.jl/blob/5ac9b3ffc5f90f5b77c4f59a5f94c73b80a567f2/src/rendering.jl#L16-L23) at `pix_per_glyph*downsample` = 320 px | an 8-bit coverage bitmap | no | **yes: the one place pixels are needed** |
| 5 | SDF step (pure Julia, SignedDistanceFields.jl) | [`sdistancefield` #L331-L353](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L331-L353) | the bitmap | no | yes (Julia, unchanged) |
| 6 | Quad geometry per glyph (ink box + padding) and uv lookup | [`Glyphs` `sdf_uv`, `quad_offset/scale` M/Makie/src/basic_recipes/glyphs.jl#L12-L30](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/glyphs.jl#L12-L30), [`glyph_boundingbox` texture_atlas.jl#L759-L764](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L759-L764) | ink box metrics | not needed (no glyph quads) | metrics from the same raster |
| 7 | WGLMakie glyph upload | [`register_glyph_computation!` M/WGLMakie/src/plot-primitives.jl#L439-L452](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/WGLMakie/src/plot-primitives.jl#L439-L452), [`GlyphSync`/`glyph_batch_js`/pull responder #L318-L383](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/WGLMakie/src/plot-primitives.jl#L318-L383), [`sync_glyphs!`/`watch_glyphs!` #L399-L437](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/WGLMakie/src/plot-primitives.jl#L399-L437), [`get_glyph_data`/`get_glyph_sdf` Makie texture_atlas.jl#L737-L751, #L784-L825](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/utilities/texture_atlas.jl#L784-L825), JS: [`insert_glyphs` WGLMakie/src/javascript/TextureAtlas.js#L79](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/WGLMakie/src/javascript/TextureAtlas.js#L79) | SDF float arrays per glyph hash, via `evaljs` | no | yes (the SDF crosses to JS) |
| 8 | Entry points / hooks | [`plot!(::Text)` text.jl#L704-L727](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L704-L727), [`register_glyph_layout!` #L499-L577](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L499-L577), [`layout_text` methods + `text_handler` protocol #L320-L455](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L320-L455), [placement #L609-L653](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L609-L653), rich text [#L1226](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L1226), LaTeX [`texelems_and_layout` #L1100](https://github.com/asinghvi17-bot/Makie.jl/blob/e2f012445e783c5bf26a88bd5bfd2455786d0d53/Makie/src/basic_recipes/text.jl#L1100) (MathTeXEngine addresses glyphs by FreeType glyph id and glyph *name*) | | | |

Consequences: only stage 4 (and the SDF that follows it) needs pixels; everything else is metrics. Makie 0.25's `text_handler` /
`layout_text(handler, src, attributes)` (text.jl#L405-L455) is a ready hook for C. MathTeXEngine's glyph ids (and names) have no
codepoint, which Canvas2D `fillText` needs: B cannot draw them (see recommendation).

## 2. B: the browser rasterizes, Julia does the rest

Code: `tooling/text-browser/probes/browser_glyphs.jl` (Julia overlays), `p_B_text.jl` (probe), WasmHost patch
`deliverable/wasmhost-text/0001-wasmhost-text-host-jobs.patch` (applies to 5cb54e3; JS adapter + Node mock + protocol docs).
Host import: `wasm_host.text_start(req, len) -> julia_io handle`, `wasm_host.text_finish(handle, res, cap) -> len`; Julia-level
`glyph_raster(font, codepoint, px) -> (bitmap, metrics)` starts the job, parks in `Runtime.Host.await_handle`, reads the bitmap, closes the handle.
Overlays (wasm only): `FTA.glyph_index(::Char)` = the codepoint (pseudo glyph index), `getproperty(::FTFont)` and `get_extent` from the host,
`find_font_for_char` = identity (the browser's font stack does the fallback), `insert_glyph!` = Makie's own body with the host bitmap
in place of `renderface`, followed by Makie's own `sdistancefield` and packer. The atlas is an empty 1024^2 one (the 8 MiB default is not baked).
Fonts are registered by the page with `FontFace` but **not loaded**: the first job loads the face, which is the asynchronous case the module parks for.

Results (`deliverable/b-results/`):
- Strict compile: clean verifier, 1479 functions, 0 unsupported; 4,785,052 bytes (0.99 MB gzip, unoptimized; the capmap atlas module is 10.1 MB / 1.9 MB gzip with a 2048^2 atlas).
  This is the first time `sdistancefield`/SignedDistanceFields and the packer are compiled strictly (the capmap atlas probe replaced them by a lookup).
  The first compile failed the verifier on my own `host_job` (a loop-reassigned `cap` captured by a closure -> `Core.Box`), fixed by moving the read into a function.
- Headless Chromium, `text!` changed at run time to `Wasm: ünï 42 ΩΣ ≈ ∞` (never rendered at build time; 19 glyphs, 15 distinct): `rc=0`, 31 host jobs (1 font, 30 glyph: an extent and a raster per distinct glyph), 16-20 s total.
- Node: same module, **MOCK backend** (synthetic ellipses, no fonts): works, 10.9 s. Plumbing only, no font fidelity claim.
- Versus native FreeType for the same text (`B_text.native.txt` vs `B_text.chromium.txt`): all 19 glyph origins and advances identical (max diff 0.000 at 3 decimals, font size 40), block bbox identical (389.4 x 46.6), font ascender/descender/height identical (947 / -218 / 1165), ink boxes within 0.005 em, SDF sizes identical, pixels inside the glyph 1027 vs 1026, 540 vs 540, 461 vs 461 (ASCII pictures in the outputs look the same).

Browser vs FreeType for TeX Gyre Heros Makie (115 glyphs, `b-compare/cmp_chromium.json`; Chromium 158 on Linux; FreeType hinted at 320 px as Makie renders):
- **Advance**: exact (0.000/1000 em) when `measureText` is taken at 1000 or 2000 px; 0.24 units off at 2048 px; 0.05 at 8192; garbage above that (Chromium clamps). The adapter uses 4000 px.
- **`actualBoundingBox*` is loose**: 8-16 units/1000 em (0.8-1.6 % of the em) larger than the FreeType unhinted box, per side, at every size. Useless for the ink box; the adapter takes the ink box from the bitmap's pixels.
- `fontBoundingBoxAscent/Descent` = hhea ascender/descender: 947 / 218, equal to FreeType's. Line gap is not available from Canvas2D; the adapter reads the CSS `line-height: normal` height from a DOM probe (1165, equal).
- **Bitmaps** at 320 px: identical bounding box (origin and size) for 93 of 115 glyphs, the rest off by 1 px (height by up to 2); mean IoU of coverage 0.995; mean |coverage difference| 0.55/255 over the union box; summed coverage within 0.03 %. (The worst glyphs, IoU 0.988: `_ V ^ ≥ W >`.)
- Host cost: a 320 px glyph (`fillText` + `getImageData` + bbox scan) ~1.0 ms; a `measureText` job 0.01 ms. **The Wasm side dominates**: the SDF step in the unoptimized module is ~0.7 s per glyph (Node mock, loaded host) against 34 ms natively. Without wasm-opt and a faster distance transform, a first-use page of ~100 glyphs would take over a minute. Not profiled further.
- Cross-browser: **only Chromium measured.** Known/expected, not verified here: Firefox and Safari have no JSPI at the time WasmHost's docs were written, so the parking path would need another design there; Linux Chromium hints advances to whole pixels at small sizes (see C), macOS browsers do not, so metrics taken at small sizes differ per platform (measure at a large size, as the adapter does); system fallback fonts (`≈ ∞` fell back in the Chromium run) differ per machine, and `document.fonts` cannot query a cmap, so "does this font have glyph X" is unanswerable (hence the pseudo glyph index and no Makie fallback chain).
- Limits of B: glyph ids are codepoints, so anything addressing glyphs by id/name (MathTeXEngine, math variants) cannot be drawn; native-built plots carry FreeType ids, so a text plot built natively and not updated would look up different atlas keys (the probe re-sets the text).

## 3. C: no SDF, labels placed by the browser

Code: `tooling/text-browser/labels/` (`browser_labels.jl`: `text_handler` + `collect_labels`; `overlay.mjs`: DOM overlay and Canvas2D layer;
`browser_labels_wasm.jl` + `p_C_text.jl`: the wasm version; `serve_and_shoot.jl`, `shoot.mjs`, `measure.mjs`, `run_all.sh`: native Axis flow).
- **Handler**: `Makie.layout_text(::Handler, ::String, attrs)` returns a layout whose width is the browser's `measureText` of each line and whose ascender/descender are the browser's font box. LaTeXString and RichText are not `String`: they fall through to Makie's own glyph layout (still needing FreeType/A/B). An empty string delegates to Makie's (an unset `subtitle` otherwise took 14 px of height: found by diffing screenshots).
- **Finding**: Axis sizes decorations from string bounding boxes built out of the per-glyph arrays (stage 3), so a layout with no glyphs but a correct `bbox` left the Axis with zero protrusions. The handler therefore emits one transparent blank glyph (the font's space) per line, whose advance is the measured width. WebGL draws nothing; every downstream measurement uses the browser's numbers.
- **Label list**: `collect_labels` reads each Text plot's resolved nodes (`input_text`, `markerspace_positions`, `align`, `rotation`, `offset`, `fontsize`, `computed_color`, `block_bboxes`, ...) and emits per line: text, baseline-left position (window px, y down), size, colour, angle, family/style, measured width. Two renderers: **DOM** (one absolutely positioned element per line, rotated about the baseline end, `line-height` = font content area so the baseline is `ascender` below the box top) and **Canvas2D** (`fillText` at the baseline). Same list for both.
- **Native Axis flow** (the Axis does not compile strictly: capmap's 439 errors): Makie lays the Axis out natively; the browser's measurements come from a TSV filled in two passes (Julia records what it needs, Chromium measures, Julia re-runs until nothing is missing; 14 entries for the plain figure). Page: WGLMakie through Bonito in headless Chromium, label layers added on top.
- **Wasm flow** (`p_C_text.jl`): `text!` with the handler, changed at run time; `text_width` and `font_metrics` are host calls (`measure`, `font` jobs of the same import). Strict compile clean, 4,662,777 bytes (0.93 MB gzip); in Chromium 2 host jobs (font + measure), 0.5 s, label printed as JSON; Node MOCK 0.58 s. Details in `c-results/C_text.results.md` (raw outputs of this run were lost with the TMPDIR; the numbers are transcribed).
  The FreeType-free overlays of capmap's `text_overrides.jl` are still included (prepared for the one blank glyph); the atlas has one entry.

Screenshots (`deliverable/c-results/`, 600x400, native WGLMakie = `*_native_none.png`; `*_c_none` = C without a label layer, `*_c_dom`, `*_c_canvas`):
- `shot_sheet.png` (plain figure: native | C none | diff | C DOM | diff | C Canvas2D | diff), `shot_native_none.png`, `shot_c_dom.png`, `shot_c_canvas.png`; zooms `zoom_title.png`, `zoom_yticks.png`.
- Mean |gray difference| to native over the image / pixels differing by more than 32: C without labels 1.43 / 2135; DOM 0.94 / 1989; Canvas2D 0.91 / 1944 (default text rendering). With `text-rendering: geometricPrecision` in measurement and drawing (`shot_plain_gp_*` were lost with the TMPDIR; numbers transcribed): Canvas2D 0.34 / 993, DOM 1.06 / 2035. Visually the plain figure is the same as native; remaining differences are sub-pixel shifts and anti-aliasing.
- `extras_pair.png` (native | C DOM): rotated tick labels (45 deg), two-line centred title, a rotated text, LaTeX xlabel, rich-text ylabel, a stroked text. `scene3d_pair.png`: a text inside a sphere in an `LScene`.

What breaks or differs (each observed unless marked):
1. **3D depth ordering** (observed): in `scene3d_pair.png` the "inside the sphere" label is occluded natively and drawn over the sphere by the overlay; labels are always above (or below) all WebGL content, and no per-label depth is possible with DOM/Canvas2D. Camera motion in the browser (Camera3D/OrbitControls run in JS) does not move the labels: positions are projected in Julia, so every camera change needs a Julia round trip (not tested; interactions are not wired in these probes).
2. **PNG export** (observed): the canvas export WGLMakie uses (`canvas.toDataURL`, `shot_c_dom_canvas_export.png`) contains no text at all. Export needs compositing the label layer (Canvas2D layer: `drawImage` it; DOM: rasterize it, e.g. via an SVG `foreignObject`, with its own font-loading problems).
3. **Stroke / glow** (observed): the white `strokecolor=:black, strokewidth=2` text is invisible (white on white) because the prototype ignores stroke; Canvas2D `strokeText` or CSS `-webkit-text-stroke` could do it (not implemented). Per-glyph colours (rich text) are not representable by a single label.
4. **Rich text and LaTeX** (observed): not handled; they keep going through glyphs and the atlas, so C does not remove FreeType from a figure that has them. A browser equivalent (MathML/KaTeX in the DOM) would give a different layout than MathTeXEngine.
5. **Consistent fonts**: pro: the page's own font stack, selectable/searchable text, crisp at any device pixel ratio, kerning and ligatures. Con: layout is the browser's, not Makie's. Linux Chromium (`text-rendering: auto`) rounds advances to whole pixels at small sizes: tick label widths 8/16/48 px against 7.78/15.57/46.7 linear (+3 %); `geometricPrecision` removes the difference (7.784 canvas and DOM at 14 px). The whole-string width also includes kerning (387.0 vs 389.4 px at 40 px). Figures therefore differ across browsers/platforms and from CairoMakie/GLMakie output.
6. **DOM vs Canvas2D**: the Canvas2D layer matches native best (0.34 vs 1.06 mean difference with `geometricPrecision`) and is the only one that composes into an export; the DOM overlay gives selectable text and accessibility but the browser snaps DOM text to whole-pixel baselines. The DOM layer needs one element per line and a stacking context over the canvas; clipping to the axis (clip planes), `overdraw`, `transparency` ordering relative to other plots are not representable.
7. Not covered by the prototype: `word_wrap_width`, `markerspace = :data` zoom behaviour, `Textbox`/`EditableText` caret metrics (they read per-glyph origins).

## 4. Recommendation

- **A (pure-Julia font parser/rasterizer) stays the foundation.** It is the only option that works for glyph ids and glyph names (MathTeXEngine, math variants), is deterministic across hosts (Node, wasmtime, browsers), and needs no JSPI. (I have not seen A's results; this assumes it reaches FreeType's metrics and a usable raster for the bundled CFF fonts.)
- **B as an optional backend behind the same `NativeFont` seam**, for what A cannot bundle: system fonts, fallback fonts, scripts and emoji. It was cheap (about 200 lines of Julia, a 300-line JS adapter) and for the bundled font it reproduces FreeType's layout exactly (advance, ascender, descender, line height) with 0.995 raster IoU. Prerequisites before it is worth shipping: a faster distance transform or doing the SDF host-side (the unoptimized Wasm SDF is ~0.7 s/glyph), wasm-opt numbers, and a plan for non-JSPI browsers.
- **C as an opt-in `text_handler` for static or lightly interactive 2D figures** (Axis tick labels, titles, labels), not a replacement: it is the smallest (2 host calls, 0.5 s, no atlas) and gives browser-quality text, but breaks 3D occlusion, PNG export (without compositing), stroke/glow, per-glyph colours, and does not cover rich text or LaTeX. Use the Canvas2D layer if export matters, the DOM layer if selectable text does.
- Combination: A (+ B for system fonts) in the glyph path for everything that must stay inside the WebGL scene (3D, LaTeX, rich text, export), C layered on top only for plain 2D strings when the user asks for it.

## Peak RSS per step (`/usr/bin/time -f %M`, process tree of that command)

| Step | Peak RSS |
|---|---|
| `Pkg.develop` + `Pkg.add` (resolve; 2 GiB reservation briefly exceeded) | 2,233,680 KB |
| `Pkg.precompile` (2nd and 3rd runs; the 1st was killed by the 10-min limit, not measured) | 1,746,340 / 1,798,440 KB |
| native baseline `text_atlas` probe (capmap) | 1,121,948 KB |
| baseline `text_atlas` strict compile | not completed (killed at the 10-min limit twice; load average ~100) |
| B native run | 1,079,920 KB |
| B strict compile, 1st (verifier failure) | not recorded |
| B strict compile, 2nd (clean) / 3rd (final, 482.6 s) | 1,808,996 / 1,832,560 KB |
| C native run | 1,153,500 KB |
| C strict compile (496.1 s) | 1,812,172 KB |
| native Axis label passes / WGLMakie servers | ~1.0-1.2 GB |
| Node mock runs (B, C) | 261,344 / 262,188 KB |
| Chromium / Playwright runs | not measured |

## Reproducing

Needs capmap's `common.jl`, `overrides.jl`, `native.jl`, `build.jl`, `text_overrides.jl` (from makie-wasm-inputs `capmap-v1`; not copied here) next to the probe files.
`julia --project=ENV build.jl p_B_text.jl out/B_text.wasm` (`Prog.CONFIG` supplies `host_extensions`, `import_libraries`, `optimize = nothing`), then
`node tooling/text-browser/host/run_chromium.mjs out/B_text.wasm out.json "<text>"` (env in the script header) or `run_node.mjs` (mock).
`labels/run_all.sh` (with `FIG=plain|extras|scene3d`) runs the native Axis flow. Network note: Pkg, git, npm and the Playwright browser
download use their own User-Agents; every request I wrote myself (and the later `git ls-remote`/push) used the required one.
