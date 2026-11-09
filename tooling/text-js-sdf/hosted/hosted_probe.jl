# julia --project=ENV hosted_probe.jl probes/p_Bsdf_text.jl: the Wasm probe program, run natively with B' hosted (see hosted_bsdf.jl): its stdout is
# diffed against the strictly compiled module's (Node mock excluded: Chromium, real glyphs). Prints "still missing: n" (then run_answer.mjs, rerun).
using WGLMakie, Makie, Observables, Bonito
using WasmCodegen, WasmCompat
probe = abspath(ARGS[1])
include(joinpath(dirname(probe), "common.jl"))       # (capmap's, next to the probe, as native.jl)
include(joinpath(dirname(probe), "overrides.jl"))
include(joinpath(@__DIR__, "hosted_bsdf.jl"))
load_host_table!(get(ENV, "HOST_TABLE", "table_probe.tsv"))
load_bsdf_hosted(joinpath(dirname(probe), "browser_glyphs_sdf.jl"))
src = read(probe, String)
src = replace(src, "include(joinpath(@__DIR__, \"browser_glyphs_sdf.jl\"))" => "")
src = replace(src, "BrowserGlyphsSDF." => "Main.BrowserGlyphsSDF.")
include_string(Main, src, probe)
isdefined(Prog, :prepare) && Prog.prepare()
rc = Base.invokelatest(Prog.main)
write(Core.stdout, "\n[main returned $rc]\n")
n = write_missing(get(ENV, "HOST_MISSING", "missing_probe.txt"))
write(stderr, "still missing: $n (host jobs $(HOST_JOBS[]))\n")
