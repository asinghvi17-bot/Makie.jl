# PureFont

A dependency-free pure-Julia reader for OpenType / TrueType fonts and a scanline rasterizer, written to replace the
FreeType calls behind Makie's text (`NativeFont = FTFont`) when compiling Makie to WebAssembly with WasmCodegen.jl.
The directory is self-contained (`Project.toml`, `src/`, `test/`) so that it can become a package.

| File | What |
|---|---|
| `src/sfnt.jl` | table directory, `head`, `hhea`, `hmtx`, `maxp`, `OS/2`, `name`, `cmap` (formats 4, 6, 12), `GlyphMetrics` |
| `src/cff.jl` | CFF 1: INDEX, DICT, FDSelect/FDArray, Type 2 charstrings (subrs, hintmask, all path and flex operators) |
| `src/glyf.jl` | `loca`/`glyf`: simple glyphs and composites (translation, scale, 2x2) |
| `src/outline.jl` | FreeType-style outline: points, on / conic / cubic tags, contour ends |
| `src/raster.jl` | exact-area coverage accumulation with the non-zero rule (FreeType's smooth scheme), FT_MulFix scaling |
| `test/parity.jl` | parity against FreeTypeAbstraction (native); results in `test/parity_results.txt` |
| `wasm/` | the Makie seam (`font_overrides.jl`) and a strict WasmCodegen probe (`p_font_runtime.jl`, `build.jl`, `run.mjs`) |

Not implemented: CFF2, `seac`, GPOS / `kern` / GSUB, hinting, composite point matching, cmap formats other than 4/6/12,
WOFF, TTC.

## Running

Native parity (needs Makie, FreeTypeAbstraction and PureFont in one environment):

    julia --project=ENV PureFont/test/parity.jl

Wasm (Julia 1.13.2, WasmCodegen @316bbaf; compile one at a time, about 1.6 GiB peak RSS):

    PF_NATIVE=ft   julia --project=ENV wasm/native.jl wasm/p_font_runtime.jl time   # FreeType reference
    PF_NATIVE=pure julia --project=ENV wasm/native.jl wasm/p_font_runtime.jl time   # PureFont, native
    julia --project=ENV wasm/build.jl wasm/p_font_runtime.jl runtime.wasm           # strict compile, atlas created at run time
    PF_PREBUILT=1 julia --project=ENV wasm/build.jl wasm/p_font_runtime.jl prebuilt.wasm   # 8 MiB atlas shipped in the module
    node wasm/run.mjs runtime.wasm time

## Results (Makie e2f01244 merged with 37cb4114; TeX Gyre Heros Makie, DejaVu Sans)

Metrics: `FontExtent` (all four vectors) equal to FreeTypeAbstraction's `get_extent` for every glyph: 1054/1054 (Regular),
1054/1054 (Bold), 6253/6253 (DejaVu Sans, incl. composites). cmap: 0 mismatches over ASCII, Latin-1 and Greek (248 chars).
Face `ascender`, `descender`, `height`, `units_per_EM`, family and style names equal.

Rendering at 320 px (`pix_per_glyph 64 * downsample 5`), then Makie's `sdistancefield(bitmap, 5, 12)`:

| vs FreeType | bitmap size equal | max / mean SDF difference (texels) |
|---|---|---|
| `FT_LOAD_NO_HINTING`, Heros Regular | 238/238 | 0.200 / 0.0031 |
| `FT_LOAD_NO_HINTING`, Heros Bold | 238/238 | 0.197 / 0.0031 |
| `FT_LOAD_NO_HINTING`, DejaVu Sans | 245/245 | 0.240 / 0.0013 |
| default (hinted, what Makie's atlas gets), Heros Regular | 233/238 | 0.200 / 0.0036 |
| default (hinted), Heros Bold | 226/238 | 0.200 / 0.0035 |
| default (hinted), DejaVu Sans | 77/245 | 0.317 / 0.029 (TrueType bytecode hinting) |

(Glyphs whose hinted bitmap differs in size are excluded from the hinted rows.)

### Wasm (strict: `verify=:error`, `host=:wasi`, `trim=:safe`; node:wasi, node v26.10.0)

`wasm/p_font_runtime.jl` calls Makie's own `glyph_uv_width!` / `get_extent` / `sdistancefield` / `TextureAtlas` over the
overrides in `wasm/font_overrides.jl`: 50 glyphs of a runtime text in Regular and Bold (ASCII, Latin-1, Greek, braces).

- Output of the wasm module is identical to the native PureFont run (extents, uv rectangles, SDF checksums), and equal to
  the native FreeType run in glyph indices, extents and uv rectangles; only the SDF checksums differ (the table above).
- Module size: 894,084 B (248 KB gzip) with the atlas created at run time; 9,480,809 B (1.82 MB gzip) with the prebuilt
  8 MiB atlas. Both contain the two font files (171 KB and 172 KB) as data.
- Time per new glyph at 320 px: wasm (node) 211-215 ms, of which the rasterizer is 0.6-0.7 ms and Makie's SDF step
  190-203 ms. Native: 52 ms with PureFont (rasterizer 0.22 ms), 62 ms with FreeType. An already rendered glyph costs
  0.0004 ms (hash lookup); the metrics of 96 uncached glyphs take 0.9-3.5 ms.
- Compile peak RSS: 1.53-1.62 GiB, 196-245 s.

Not done: the scene-level probes (`text!` in a `Scene` with WGLMakie) need WasmCompat's `Observables` extension
(`feat/observables-ext` @8df2164), which could not be used in this run.
