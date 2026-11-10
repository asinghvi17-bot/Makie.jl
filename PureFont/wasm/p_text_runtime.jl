# Scene-level text with the pure-Julia font stage: like capmap's p_text_atlas.jl (a text! plot built natively, its text
# changed at run time), but with no prerendered atlas and no recorded character set: PureFont parses the font and renders
# each glyph into a runtime atlas when the text first uses it, so characters outside printable ASCII work.
#
# Needs the capmap probe harness (common.jl, overrides.jl, build.jl, native.jl) and, for the scene helpers it reuses
# (`no_text_specs!`, `typed_text_args!` and the ComputePipeline overlays), capmap's text_overrides.jl:
#   CAPMAP_PROBES=<dir of capmap/probes> julia --project=ENV $CAPMAP_PROBES/build.jl p_text_runtime.jl out.wasm
# (PureFontOverrides is defined after TextOverrides, so its overlays of the same methods replace the build-time-atlas ones.)
module Prog
using Makie, WGLMakie, GeometryBasics
using ..Common
using ..Common: out, flush!, serialize_and_watch!, close_world!
include(joinpath(ENV["CAPMAP_PROBES"], "text_overrides.jl"))
include(joinpath(@__DIR__, "font_overrides.jl"))
const SCENE = Scene(size = (200, 150), camera = cam2d!)
const P = text!(SCENE, [Point2f(0, 0)]; text = ["hello"], color = RGBAf(1, 0, 0, 1))
const PLOTS = serialize_and_watch!(SCENE)
main() = Common.guard(main_)
function main_()
    Makie.update!(P; text = ["Wasm 1.25 {ok}!"])
    flush!(PLOTS, "ascii")
    Makie.update!(P; arg1 = [Point2f(1, 1)], color = RGBAf(0.2, 0.4, 0.6, 1.0))
    flush!(PLOTS, "position and color")
    Makie.update!(P; text = ["Ω"])                       # (the capmap atlas build errors here)
    flush!(PLOTS, "greek")
    Makie.update!(P; text = ["Wörld ÀÉÎ αβγ ñ ß ©"])      # (Latin-1 and Greek, none in the build-time text)
    flush!(PLOTS, "latin-1 and greek")
    return 0
end
function prepare()
    # (the plot's `font` is the symbol :regular, resolved through the theme's `fonts`)
    fonts = P.fonts[]
    PureFontOverrides.register!((Makie.to_font(fonts[k][]) for k in (:regular, :bold, :italic, :bold_italic))...)
    TextOverrides.no_text_specs!(P)
    TextOverrides.typed_text_args!(P)
    close_world!(SCENE; updates = [(P, :text), (P, :arg1), (P, :color)])
end
end
