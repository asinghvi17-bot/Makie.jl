# B (Julia SDF), with per-glyph SDF statistics for all distinct glyphs, to be compared with p_Bsdf_text.jl (B'): text whose glyphs are rasterized by the browser. Built natively with "hello" (atlas empty but for those four glyphs),
# then changed at run time to a string from the environment (TEXT): glyphs that were never rendered, in any set. In Wasm every
# FreeType call is the host's (browser_glyphs.jl). Prints what the layout and the atlas hold, so the native run (FreeType) and
# the browser run can be compared number by number.
module Prog
using Makie, WGLMakie, GeometryBasics, WasmCodegen
import FreeTypeAbstraction as FTA
using ..Common
using ..Common: out, flush!, serialize_and_watch!, close_world!
include(joinpath(@__DIR__, "text_common.jl"))
include(joinpath(@__DIR__, "browser_glyphs.jl"))
const CONFIG = (; host_extensions = [:julia_io], import_libraries = ["wasm_host"], optimize = nothing)
const ATLAS0 = BrowserGlyphs.prepare!()
const SCENE = Scene(size = (400, 150), camera = cam2d!)
const P = text!(SCENE, [Point2f(10, 10)]; text = ["hello"], color = RGBAf(1, 0, 0, 1), fontsize = 40)
const PLOTS = serialize_and_watch!(SCENE)
const N_INDICES = P.attributes[:glyph_indices]
const N_FONTS = P.attributes[:glyph_fonts]
const N_EXTENTS = P.attributes[:glyph_extents]
const N_ORIGINS = P.attributes[:glyph_layout_origins]
const N_BBOXES = P.attributes[:block_bboxes]

r3(x) = string(round(Float64(x); digits = 3))

# the SDF of a glyph as a coarse picture: '#' inside (the SDF is negative there), '.' outside
function picture(sdf::Matrix{Float16})
    io = IOBuffer()
    w, h = size(sdf)
    for y in 1:5:h
        for x in 1:3:w
            print(io, sdf[x, y] < 0 ? '#' : '.')
        end
        print(io, '\n')
    end
    return String(take!(io))
end

function report(tag::String)
    atlas = ATLAS0
    gis = N_INDICES[]::Vector{UInt64}
    fonts = N_FONTS[]::Vector{Makie.NativeFont}
    exts = N_EXTENTS[]::Vector{Makie.GlyphExtent}
    ors = N_ORIGINS[]::Vector{Point3f}
    out(string("== ", tag, ": ", length(gis), " glyphs; atlas entries ", length(atlas.uv_rectangles), "\n"))
    bb = (N_BBOXES[]::Vector{Rect2f})[1]
    out(string("bbox ", r3(bb.origin[1]), " ", r3(bb.origin[2]), " ", r3(bb.widths[1]), " ", r3(bb.widths[2]),
               "; font ", fonts[1].ascender, " ", fonts[1].descender, " ", fonts[1].height, " ", fonts[1].units_per_EM, "\n"))
    shown = Set{UInt64}()
    for i in eachindex(gis)
        e = exts[i]
        ib = e.ink_bounding_box
        out(string("glyph ", i, " origin ", r3(ors[i][1]), " ", r3(ors[i][2]), " hadvance ", r3(e.hadvance), " ink ",
                   r3(ib.origin[1]), " ", r3(ib.origin[2]), " ", r3(ib.widths[1]), " ", r3(ib.widths[2]), "\n"))
    end
    for i in eachindex(gis)
        gis[i] in shown && continue
        push!(shown, gis[i])
        hash, _, ff = Makie.get_marker_hash(atlas, gis[i], fonts[i])
        sdf = Makie.get_glyph_sdf(atlas, hash)
        inside = 0
        total = 0.0
        for v in sdf
            v < 0 && (inside += 1)
            total += Float64(v)
        end
        # (every distinct glyph: size, pixels inside, sum of the Float16 tile; the first three also as a picture)
        out(string("sdf of glyph ", i, " (index ", gis[i], "): ", size(sdf, 1), "x", size(sdf, 2), " inside ", inside, " sum ", r3(total), "\n"))
        length(shown) <= 3 && out(picture(sdf))
    end
    return
end

# (an exception shown by its own message, which `Common.describe` does not do for the host's errors)
function main()
    try
        return main_()::Int
    catch e
        inner = e isa Makie.ComputePipeline.ResolveException ? e.error : e
        out(string("EXCEPTION: ", WasmCodegen.Runtime.Host.error_text(inner), "\n"))
        return 1
    end
end
function main_()
    s = get(ENV, "TEXT", "Wasm: ünï 42 ΩΣ ≈ ∞")
    Makie.update!(P; text = [s])
    flush!(PLOTS, "runtime text")
    report("after update!(text)")
    return 0
end
function prepare()
    TextCommon.no_text_specs!(P)
    TextCommon.typed_text_args!(P)
    close_world!(SCENE; updates = [(P, :text), (P, :arg1), (P, :color)])
end
end
