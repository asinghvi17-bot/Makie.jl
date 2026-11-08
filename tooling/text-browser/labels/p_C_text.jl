# C: text laid out with the browser's metrics, no glyph raster, no SDF. Built natively with "hello", then changed at run time to a
# string from the environment (TEXT): its width, and the font's ascender/descender, are `measureText`/`fontBoundingBox` results the host
# returns. The program prints the label list (JSON, one line) for a DOM overlay or a Canvas2D layer, and the layout numbers.
# The only glyph left in WebGL is one blank (transparent space) glyph per line that carries the measured width (see Handler's docs);
# it is the one entry of the atlas, prerendered at build time.
module Prog
using Makie, WGLMakie, GeometryBasics, WasmCodegen
using ..Common
using ..Common: out, flush!, serialize_and_watch!, close_world!
include(joinpath(@__DIR__, "text_overrides.jl"))      # capmap's FreeType-free text overrides, with a one-glyph atlas
include(joinpath(@__DIR__, "browser_labels.jl"))
include(joinpath(@__DIR__, "browser_labels_wasm.jl"))
using .BrowserLabels
const CONFIG = (; host_extensions = [:julia_io], import_libraries = ["wasm_host"], optimize = nothing)
const FONT = Makie.to_font("TeX Gyre Heros Makie")
Makie.TEXTURE_ATLASES[(2048, 64)] = Makie.TextureAtlas(; resolution = 1024)    # (empty; get_texture_atlas() is this one)
BrowserLabels.register_fonts!(FONT)
const SCENE = Scene(size = (400, 150), camera = cam2d!)
update_cam!(SCENE, Rect2f(0, 0, 400, 150))             # (data units are pixels)
const P = text!(SCENE, [Point2f(10, 10)]; text = ["hello"], color = RGBAf(1, 0, 0, 1), fontsize = 40, text_handler = BrowserLabels.Handler())
const PLOTS = serialize_and_watch!(SCENE)
const N_TEXT = P.attributes[:input_text]
const N_POS = P.attributes[:markerspace_positions]
const N_ALIGN = P.attributes[:align]
const N_ROT = P.attributes[:rotation]
const N_OFFSET = P.attributes[:offset]
const N_FONT = P.attributes[:selected_font]
const N_SIZE = P.attributes[:fontsize]
const N_COLOR = P.attributes[:computed_color]
const N_BBOX = P.attributes[:block_bboxes]
const N_BASE = P.attributes[:block_baselines]
const N_LH = P.attributes[:lineheight]
const N_JUST = P.attributes[:resolved_justification]
const N_GI = P.attributes[:glyph_indices]
const N_EXT = P.attributes[:glyph_extents]

r3(x) = string(round(Float64(x); digits = 3))

main() = Common.guard(main_)
function main_()
    s = get(ENV, "TEXT", "Wasm: ünï 42 ΩΣ ≈ ∞")
    Makie.update!(P; text = [s])
    flush!(PLOTS, "runtime text")
    labels = BrowserLabels.Label[]
    skipped = String[]
    bb = (N_BBOX[]::Vector{Rect2f})[1]
    out(string("layout bbox ", r3(bb.origin[1]), " ", r3(bb.origin[2]), " ", r3(bb.widths[1]), " ", r3(bb.widths[2]), "; blank glyphs ", length(N_GI[]::Vector{UInt64}), "\n"))
    BrowserLabels.labels_from!(labels, skipped, BrowserLabels.METRICS[], N_TEXT[]::Vector{String}, N_POS[]::Vector{Point3f}, N_ALIGN[]::Tuple{Symbol, Symbol},
                               N_ROT[]::Makie.Quaternion{Float64}, N_OFFSET[]::Vec3f, N_FONT[]::Makie.NativeFont, N_SIZE[]::Float32, N_COLOR[]::RGBAf,
                               N_BBOX[]::Vector{Rect2f}, N_BASE[]::Vector{Float32}, N_LH[]::Float64, N_JUST[]::Float32, Point2f(0, 0), 150.0f0)
    out(string("LABELS ", BrowserLabels.labels_json(labels, (400, 150)), "\n"))
    return 0
end
function prepare()
    TextOverrides.prepare!([' '])
    TextOverrides.no_text_specs!(P)
    TextOverrides.typed_text_args!(P)
    close_world!(SCENE; updates = [(P, :text), (P, :arg1), (P, :color)])
end
end
