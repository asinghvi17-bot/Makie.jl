# Pure-Julia font stage for Makie in wasm: notes and what is in this directory

Code is in `PureFont/` (commit on branch `trim/pure-julia-font`); this directory holds the run notes that do not belong in a package.

- `setup_env.sh CLONE`, `pkg_setup.jl`: rebuild the scratch environment (scratch clone of the checkout merged with 37cb4114, WasmCodegen @316bbaf,
  WasmCompat `feat/observables-ext` @8df2164 from asinghvi17-bot/WasmCompat.jl, capmap inputs). Then `Pkg.precompile()` (about 17 min over 3 runs).
- `outputs/`: scene-level probe (`PureFont/wasm/p_text_runtime.jl`) digests: native FreeType, wasm, their diff, the wasm section sizes.
- `tools/find_reachable_atlas.jl`, `tools/wasm_sections.py`: the scripts used to look for the 8 MiB atlas (see below).

## Results from the first session (outputs were lost with $TMPDIR; numbers are in PureFont/README.md too)
Native parity: `PureFont/test/parity_results.txt`. Reduced wasm program (`p_font_runtime.jl`): 894,084 B without atlas, 9,480,809 B with the prebuilt atlas,
211-215 ms per new glyph in node (rasterizer 0.6-0.7 ms, SDF 190-203 ms), outputs identical to the native PureFont run.

## Scene-level probe, with WasmCompat @8df2164 (second session)
`PureFont/wasm/p_text_runtime.jl` = capmap's `p_text_atlas.jl` with no prerendered atlas and no recorded character set (it reuses `text_overrides.jl`'s
scene helpers `no_text_specs!`/`typed_text_args!`, and PureFontOverrides replaces its font/atlas overlays).
- Native FreeType run: 4 steps, `[main returned 0]`.
- Strict compile (`verify=:error`, `host=:wasi`, `trim=:safe`, `shell_first_mutables=true`): clean, 11,436,960 B, 513 s, peak RSS 1,900,784 KB (1.81 GiB).
- Wasm run in node:wasi: `[main returned 0]`; peak RSS of node 342,276 KB. The digest equals native FreeType on every step (hashes, scales, marker_offset, positions) except
  the second step, where wasm also resends `glyph_data` (the `is_same(Dict{Symbol,Any}) = false` override of text_overrides.jl; capmap's own `text_atlas.diff` has the same difference).
  The new steps, "Ω" (which capmap's atlas build rejects) and "Wörld ÀÉÎ αβγ ñ ß ©", work and equal native.
- Glyphs are rendered by PureFont into a run-time atlas (its mapping starts empty, so every glyph of the text goes through PureFont's rasterizer and Makie's `sdistancefield` in wasm).

### Open: the module is 11.4 MB, not smaller
The scene-level module is not smaller than capmap's 10.1 MB: a data segment of exactly 8,388,608 B (a 2048 x 2048 Float16 atlas with about 1.1M non-background values, i.e. Makie's cached
native atlas) is still in it. Tried and ruled out (size unchanged to within 700 B): `empty!(Makie.TEXTURE_ATLASES)`; replacing the `atlas` node value of every plot's graph by a 1 x 1 atlas after
`close_world!` (a BFS from the scene then finds no atlas or Float16 array); the same replacement before `close_world!` (StaticDispatch then logs "texture atlas is too small" from a node it
re-evaluates, so that variant is not usable). A BFS over every constant of every loaded module (depth 6) finds no `TextureAtlas`. Where it is held was not found; candidates left: a constant
baked into code by StaticDispatch or WasmCodegen, or a reference that only exists during compilation. The reduced program (no scene) does not contain it, so the atlas-free size there (894 KB)
is the number for the font stage itself.
