# Text without FreeType at run time, any glyph: the fonts are parsed and rasterized by PureFont in Julia, and the
# glyphs are rendered into the texture atlas when first used (Makie's `sdistancefield` is the SDF step, unchanged).
#
# It replaces what `text_overrides.jl` of the capmap probes does with a build-time atlas and recorded metrics, at the
# same seams: `glyph_index`, the FT_FaceRec fields, `get_extent`, `find_font_for_char`, `get_texture_atlas` and
# `insert_glyph!` (which now renders). Wasm only (overlays): the native run keeps FreeType, the reference.
# `install_native!()` defines the same replacements as ordinary methods, for a native run of the same code.
module PureFontOverrides
using WasmCodegen, Makie, PureFont
import FreeTypeAbstraction as FTA
const WASM = WasmCodegen.Runtime.WASM_METHODS

const FONTS = IdDict{FTA.FTFont, PureFont.Font}()
const ATLAS = Ref{Union{Nothing, Makie.TextureAtlas}}(nothing)

"Natively, at build time: parse `fonts`' files (the bytes FreeType mmapped) with PureFont."
function register!(fonts...)
    for f in fonts
        mm = getfield(f, :mmapped)
        mm === nothing && error("font $(f) has no file data")
        FONTS[f] = PureFont.Font(Vector{UInt8}(mm))
    end
    return
end

"Natively, at build time: render `chars` of `fonts` into the (FreeType-rendered) atlas that ships with the module."
function prebuild_atlas!(chars, fonts...)
    atlas = Makie.get_texture_atlas()
    for f in fonts, c in chars
        FTA.glyph_index(f, c) == 0 || Makie.glyph_uv_width!(atlas, c, f)
    end
    ATLAS[] = atlas
    return
end

@noinline no_glyph(c) = error(string("text: no font has the character ", c))
@noinline no_bezier() = error("text: BezierPath markers are not supported in this build")
@noinline atlas_full() = error("texture atlas is too small")
@noinline unknown_font() = error("text: font was not registered with PureFontOverrides.register!")
pf(font::FTA.FTFont) = get(FONTS, font, nothing)::Union{Nothing, PureFont.Font}
function pfont(font::FTA.FTFont)
    f = pf(font)
    f === nothing && unknown_font()
    return f::PureFont.Font
end

# (types.jl:233) `FT_Get_Char_Index`
pf_glyph_index(face::FTA.FTFont, c::Char) = UInt64(PureFont.glyph_index(pfont(face), c))

# (types.jl:176) the C fields of FT_FaceRec; Julia fields as they are. The method is written out so that a constant
# `s` folds and each field has its own type (a helper function would infer to a Union).
const GETPROPERTY = :(function Base.getproperty(font::FTA.FTFont, s::Symbol)
    s === :height && return Int16(PureFontOverrides.pfont(font).height)
    s === :units_per_EM && return UInt16(PureFontOverrides.pfont(font).units_per_em)
    s === :ascender && return Int16(PureFontOverrides.pfont(font).ascender)
    s === :descender && return Int16(PureFontOverrides.pfont(font).descender)
    s === :family_name && return PureFontOverrides.pfont(font).family_name
    s === :style_name && return PureFontOverrides.pfont(font).style_name
    s === :num_glyphs && return PureFontOverrides.pfont(font).num_glyphs
    return getfield(font, s)
end)

# (types.jl:219, :242) `internal_get_extent` with `FT_LOAD_NO_SCALE`, normalised by units_per_EM
function pf_extent(face::FTA.FTFont, gi::UInt64)
    f = pfont(face)
    m = PureFont.glyph_metrics(f, Int(gi))
    s = Float32(f.units_per_em)
    return FTA.FontExtent{Float32}(
        FTA.Vec{2, Float32}(Float32(m.vert_bearing_x) / s, Float32(m.vert_bearing_y) / s),
        FTA.Vec{2, Float32}(Float32(m.hori_bearing_x) / s, Float32(m.hori_bearing_y) / s),
        FTA.Vec{2, Float32}(Float32(m.hori_advance) / s, Float32(m.vert_advance) / s),
        FTA.Vec{2, Float32}(Float32(m.width) / s, Float32(m.height) / s))
end
function pf_get_extent(face::FTA.FTFont, glyphspec)
    gi = FTA.glyph_index(face, glyphspec)
    cache = FTA.get_cache(face)
    ext = get(cache, gi, nothing)
    ext !== nothing && return ext
    ext = pf_extent(face, gi)
    cache[gi] = ext
    return ext
end

# (Makie/src/utilities/texture_atlas.jl:239) no fallback fonts yet
function pf_find_font_for_char(glyph::Char, font::Makie.NativeFont)
    (pf_glyph_index(font, glyph) != 0 || glyph in ('\n', '\r', '\t')) && return font
    no_glyph(glyph)
end

# (texture_atlas.jl:139) one atlas, created when first used (it is not part of the module)
function pf_get_texture_atlas(resolution::Int, pix_per_glyph::Int)
    a = ATLAS[]
    a !== nothing && return a
    atlas = Makie.TextureAtlas(; resolution, pix_per_glyph)
    ATLAS[] = atlas
    return atlas
end

# (texture_atlas.jl:376-407) `render(atlas, (glyph_index, font))` with PureFont instead of FreeType
function pf_render(atlas::Makie.TextureAtlas, glyph_index::UInt64, font::Makie.NativeFont)
    f = pfont(font)
    gi = Int(glyph_index)
    gi == 0 && (gi = PureFont.glyph_index(f, ' '))   # (as Makie: newline and the like are rendered as a space)
    bitmap, _, _ = PureFont.render_glyph(f, gi, Int(atlas.pix_per_glyph) * Int(atlas.downsample))
    sd = Makie.sdistancefield(bitmap, Int(atlas.downsample), Int(atlas.glyph_padding))
    uv = push!(atlas.rectangle_packer, Makie.Rect2{Int32}(0, 0, size(sd)...))
    uv === nothing && atlas_full()
    atlas.data[uv.area] = sd
    return uv.area
end

# (texture_atlas.jl:288) `insert_glyph!`, as Makie's for a glyph, without the BezierPath render
function pf_insert_glyph!(atlas::Makie.TextureAtlas, hash::UInt32, path_or_glyph)
    path_or_glyph isa Makie.BezierPath && no_bezier()
    glyph_index, font = path_or_glyph::Tuple{UInt64, Makie.NativeFont}
    idx = get(atlas.mapping, hash, 0)
    idx != 0 && return idx
    uv_pixel = pf_render(atlas, glyph_index, font)
    tex_size = Makie.Vec2f(size(atlas))
    idx_left_bottom = minimum(uv_pixel)
    idx_right_top = maximum(uv_pixel)
    uv_left_bottom_pad = (idx_left_bottom .+ 0.5) ./ tex_size
    uv_right_top_pad = (idx_right_top .- 0.5) ./ tex_size
    push!(atlas.uv_rectangles, Makie.Vec4f(uv_left_bottom_pad..., uv_right_top_pad...))
    atlas.mapping[hash] = length(atlas.uv_rectangles)
    return length(atlas.uv_rectangles)
end

Base.Experimental.@overlay WASM FTA.glyph_index(face::FTA.FTFont, c::Char) = pf_glyph_index(face, c)
@eval Base.Experimental.@overlay WASM $GETPROPERTY
Base.Experimental.@overlay WASM FTA.get_extent(face::FTA.FTFont, glyphspec) = pf_get_extent(face, glyphspec)
Base.Experimental.@overlay WASM Makie.find_font_for_char(glyph::Char, font::Makie.NativeFont) = pf_find_font_for_char(glyph, font)
Base.Experimental.@overlay WASM Makie.find_font_for_char(glyph::Integer, font::Makie.NativeFont) = font
Base.Experimental.@overlay WASM Makie.get_texture_atlas(resolution::Int, pix_per_glyph::Int) = pf_get_texture_atlas(resolution, pix_per_glyph)
Base.Experimental.@overlay WASM Makie.insert_glyph!(atlas::Makie.TextureAtlas, hash::UInt32,
    path_or_glyph::Union{Makie.BezierPath, Tuple{UInt64, Makie.NativeFont}}) = pf_insert_glyph!(atlas, hash, path_or_glyph)

"The same replacements as ordinary methods (a native process only: it overwrites FreeTypeAbstraction's and Makie's)."
function install_native!()
    @eval FTA.glyph_index(face::FTA.FTFont, c::Char) = $pf_glyph_index(face, c)
    @eval $GETPROPERTY
    @eval FTA.get_extent(face::FTA.FTFont, glyphspec) = $pf_get_extent(face, glyphspec)
    @eval Makie.find_font_for_char(glyph::Char, font::Makie.NativeFont) = $pf_find_font_for_char(glyph, font)
    @eval Makie.get_texture_atlas(resolution::Int, pix_per_glyph::Int) = $pf_get_texture_atlas(resolution, pix_per_glyph)
    @eval Makie.insert_glyph!(atlas::Makie.TextureAtlas, hash::UInt32,
        path_or_glyph::Union{Makie.BezierPath, Tuple{UInt64, Makie.NativeFont}}) = $pf_insert_glyph!(atlas, hash, path_or_glyph)
    return
end
end
