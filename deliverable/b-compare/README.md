Scripts of the Canvas2D vs FreeType comparison (B). `ft_ref.jl` dumps FreeType's metrics and 320 px bitmaps for TeX Gyre Heros Makie;
`cmp.html` + `runcmp.mjs` render the same glyphs with Canvas2D in Chromium and compare (`cmp_chromium.json` is the result).
`advtest.mjs`, `tr.mjs`, `bench.mjs`, `sdf_time.jl` are the small follow-up experiments of REPORT.md (rewritten from the session
after its TMPDIR was reaped; they were run as written there, but not re-run from this copy).
