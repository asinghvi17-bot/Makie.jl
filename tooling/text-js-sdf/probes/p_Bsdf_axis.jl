# B' under an Axis with tick labels: capmap's p_A_axis.jl (a Figure + Axis + lines built natively; at run time new data, then reset_limits!:
# ticks, tick labels, layout) with every FreeType call replaced by the host (browser_glyphs_sdf.jl) instead of the build-time atlas. Expected not to
# compile strictly: capmap's Axis has 439 verifier errors outside text (ComputePipeline, conversions, colormap); this probe asks whether text adds any.
module Prog
using Makie, WGLMakie, GeometryBasics, WasmCodegen
import FreeTypeAbstraction as FTA
using ..Common
using ..Common: out, flush!, serialize_and_watch!, close_world!
include(joinpath(@__DIR__, "text_common.jl"))
include(joinpath(@__DIR__, "browser_glyphs_sdf.jl"))
const CONFIG = (; host_extensions = [:julia_io], import_libraries = ["wasm_host"], optimize = nothing)
const ATLAS0 = BrowserGlyphsSDF.prepare!([Makie.to_font("TeX Gyre Heros Makie"), Makie.to_font("TeX Gyre Heros Makie Bold")])
const FIG = Figure(size = (400, 300))
const AX = Axis(FIG[1, 1]; title = "probe")
const P = lines!(AX, Point2f.(Float32[1, 2, 3, 4], Float32[1, 3, 2, 4]))
const T_arg1 = P.arg1[]::Any
Makie.update_state_before_display!(FIG)
const SCENE = FIG.scene
const PLOTS = serialize_and_watch!(SCENE)
main() = Common.guard(main_)
function main_()
    out(string("atomic plots: ", length(PLOTS), "\n"))
    Makie.update!(P; arg1 = [p * 3.0f0 for p in (P.arg1[]::typeof(T_arg1))])
    flush!(PLOTS, "data")
    reset_limits!(AX)
    flush!(PLOTS, "reset_limits!")
    return 0
end
function prepare()
    for p in Iterators.flatten((AX.blockscene.plots, AX.scene.plots))
        p isa Makie.Text && (TextCommon.no_text_specs!(p); TextCommon.typed_text_args!(p))
    end
    close_world!(SCENE)   # (full install: reset_limits! updates many Axis inputs)
end
end
