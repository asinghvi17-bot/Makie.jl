Route B′ (SDF computed by the browser's JS) and route C′ (canvas-texture sprites): scripts. Results and method: `deliverable/b-prime/REPORT.md`.

- `probes/`: Julia probes (`browser_glyphs_sdf.jl` = B′ overlays; `p_Bsdf_text.jl`, `p_Bjulia_text.jl`, `p_Bsdf_axis.jl`). They `include` capmap's `common.jl`/`overrides.jl` (private repo) and `tooling/text-browser/probes/text_common.jl`.
- `host/`: Node (mock backend) and Chromium runners for a compiled module (copied from `tooling/text-browser/host`, same env variables).
- `native/sdf_ref.jl`: FreeType bitmaps and Makie's own SDF tiles for 115 glyphs. `node/algo_check.mjs`: same bitmap through the JS SDF. `browser/sdf_cmp.*`, `browser/run_sdf_cmp.mjs`: the browser's raster through the JS SDF against Makie.
- `hosted/`: the B′ Julia source run natively with the host's answers recorded from the real adapter in Chromium; `run_hosted.sh`, `compare_shots.py`.
- `cprime/`: canvas-texture sprites with depth test (`label_sprites.mjs`), the LScene comparison.
The JS SDF itself is in the WasmHost patch `deliverable/wasmhost-text/0002-wasmhost-text-sdf-job.patch` (`js/common/sdf.mjs`, tiny-sdf's BSD-2 header kept).
