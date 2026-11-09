# Option B': the browser rasterizes AND computes the SDF tile (JS: WasmHost js/common/sdf.mjs, an EDT port of tiny-sdf); Julia inserts it unchanged.
# (browser_glyphs.jl, option B, with `render_glyph` changed: the host's `sdf` job returns the finished tile at the atlas's downsample and padding.)
# Option B (the original header): the browser rasterizes, Julia does the rest. Wasm-only overlays (WasmCodegen's `WASM_METHODS`), so the native
# program keeps FreeType and stays the reference. Replaces every FreeType call of the text path:
#
#   FTA.glyph_index(font, ::Char)  -> the codepoint (a pseudo glyph index: the browser's cmap is the browser's)
#   getproperty(::FTFont, ...)     -> the font's metrics, from the host (`font` job)
#   FTA.get_extent(font, glyph)    -> the glyph's metrics, from the host (`extent` job: advance and ink box)
#   Makie.insert_glyph!(atlas, hash, (gi, font)) -> the host's finished SDF tile (`sdf` job: Makie's `sdistancefield` result, computed in JS),
#                                    then Makie's own rectangle packing and atlas write (texture_atlas.jl:288-300)
#
# The host import is `wasm_host.text_start(req, req_len) -> handle` / `text_finish(handle, res, res_cap) -> len`
# (WasmHost js/common/text.mjs documents the protocol). The module waits for the handle with
# `Runtime.Host.await_handle`: the whole module suspends (JSPI) in a program of one task; with `Config(tasks = :jspi)`
# the same call parks only the calling Julia task. Needs `Config(host_extensions = [:julia_io],
# import_libraries = ["wasm_host"])`.
module BrowserGlyphsSDF
using WasmCodegen, Makie
import FreeTypeAbstraction as FTA
using GeometryBasics: Rect2, Vec2f
const WASM = WasmCodegen.Runtime.WASM_METHODS
const Staging = WasmCodegen.Runtime.Staging
const Host = WasmCodegen.Runtime.Host

## what the program knows of a font at build time: the CSS font it asks the browser for

struct CSSFont
    style::String      # "", "bold", "italic", "italic bold"
    family::String
end
const CSS = Dict{String, CSSFont}()            # FTFont.fontname => the browser's font
const ATLAS = Ref{Makie.TextureAtlas}()

"Natively, at build time: the browser fonts of `fonts`, and an empty atlas that is the default one."
function prepare!(fonts = [Makie.to_font("TeX Gyre Heros Makie")]; resolution = 1024)
    for f in fonts
        style = f.style_name
        words = String[]
        occursin("Italic", style) && push!(words, "italic")
        occursin("Bold", style) && push!(words, "bold")
        CSS[f.fontname] = CSSFont(join(words, ' '), f.family_name)
    end
    atlas = Makie.TextureAtlas(; resolution)
    Makie.TEXTURE_ATLASES[(2048, 64)] = atlas       # (what `get_texture_atlas()` returns, also for plots made natively)
    ATLAS[] = atlas
    return atlas
end

## the host's jobs

@noinline host_error(what, h::Int32) = error(string("text host: ", what, " (", h, ")"))
@noinline host_error(what) = error(string("text host: ", what))

"Run the job `req` on the host, waiting for it (the module parks on the job's julia_io handle); its response."
function host_job(req::String)::Vector{UInt8}
    h = Staging.with_scope() do
        n = sizeof(req)
        off = Staging.alloc_data(n; align = 1)
        Staging.copy_to_linear!(off, req, 1, n)
        ccall((:text_start, "wasm_host"), Int32, (UInt32, UInt32), off, UInt32(n))
    end
    h > 0 || host_error("the host starts no text jobs (is its adapter installed?)", h)
    try
        Host.await_handle(h)
        cap = Int(Staging.CHUNK) ÷ 4
        while true
            len, buf = finish(h, cap)
            len == 0 && host_error("no response")
            len > 0 && return buf
            cap = Int(-len)
            cap > Int(Staging.CHUNK) && host_error("a response larger than the staging chunk")
        end
    finally
        Host.close(h)
    end
end

# (the response of the finished job `h` in a buffer of `cap` bytes: its length, or minus the length needed; its own function
# so that `cap` is not a variable that a closure captures and the loop reassigns)
function finish(h::Int32, cap::Int)::Tuple{Int32, Vector{UInt8}}
    return Staging.with_scope() do
        res = Staging.alloc_data(cap; align = 1)
        len = ccall((:text_finish, "wasm_host"), Int32, (Int32, UInt32, UInt32), h, res, UInt32(cap))
        len <= 0 && return (len, UInt8[])
        buf = Vector{UInt8}(undef, len)
        Staging.copy_from_linear!(buf, 1, res, Int(len))
        return (len, buf)
    end
end

i32(b::Vector{UInt8}, i::Int) = (UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24) % Int32
em6(b::Vector{UInt8}, i::Int) = Float32(i32(b, i)) / 1.0f6

function request(kind::String, font::Makie.NativeFont, rest::String)
    css = get(CSS, font.fontname, nothing)
    css === nothing && host_error(string("a font that is not registered for the browser: ", font.fontname))
    return string("wasm-text 1\n", kind, "\n", css.style, "\n", css.family, rest)
end

function checked(b::Vector{UInt8})
    (length(b) >= 8 && i32(b, 1) == 1) || host_error("a malformed response")
    st = i32(b, 5)
    st == 0 || host_error(string("the host failed: ", String(b[45:end])), st)
    return b
end

## fonts

struct FontInfo
    height::Int16
    units_per_EM::UInt16
    ascender::Int16
    descender::Int16
end
const FONTS = Dict{String, FontInfo}()

function info(font::Makie.NativeFont)::FontInfo
    name = getfield(font, :fontname)
    f = get(FONTS, name, nothing)
    f === nothing || return f
    b = checked(host_job(request("font", font, "")))
    # (the em is 1000 units: what the browser reports as a fraction of the em)
    fi = FontInfo(round(Int16, em6(b, 17) * 1000), UInt16(1000), round(Int16, em6(b, 9) * 1000), round(Int16, em6(b, 13) * 1000))
    FONTS[name] = fi
    return fi
end

Base.Experimental.@overlay WASM function Base.getproperty(font::FTA.FTFont, s::Symbol)
    s === :height && return info(font).height
    s === :units_per_EM && return info(font).units_per_EM
    s === :ascender && return info(font).ascender
    s === :descender && return info(font).descender
    s === :family_name && return CSS[getfield(font, :fontname)].family
    return getfield(font, s)
end

## glyphs

struct Raster
    bitmap::Matrix{UInt8}    # (width, rows), as FreeTypeAbstraction's `glyphbitmap`
    extent::FTA.FontExtent{Float32}
end

function parse_glyph(b::Vector{UInt8}, withbitmap::Bool)::Raster
    checked(b)
    w, h = Int(i32(b, 9)), Int(i32(b, 13))
    adv, ibx, iby, iw, ih = em6(b, 25), em6(b, 29), em6(b, 33), em6(b, 37), em6(b, 41)
    ext = FTA.FontExtent{Float32}(Vec2f(0, 0), Vec2f(ibx, iby), Vec2f(adv, 0), Vec2f(iw, ih))
    bitmap = Matrix{UInt8}(undef, withbitmap ? w : 0, withbitmap ? h : 0)
    if withbitmap
        withbitmap && length(b) >= 44 + w * h || host_error("a bitmap shorter than its size")
        k = 44
        for r in 1:h, c in 1:w
            k += 1
            @inbounds bitmap[c, r] = b[k]
        end
    end
    return Raster(bitmap, ext)
end

"The finished SDF tile of the glyph `cp` of `font` (rasterized at `px` pixels, downsampled by `ds`, padded by `pad` tile pixels): `Makie.sdistancefield`'s result, computed by the host."
function parse_sdf(b::Vector{UInt8})::Matrix{Float32}
    checked(b)
    tw, th = Int(i32(b, 9)), Int(i32(b, 13))
    length(b) >= 44 + 4 * tw * th || host_error("an SDF tile shorter than its size")
    sd = Matrix{Float32}(undef, tw, th)
    k = 45
    for j in 1:th, i in 1:tw
        @inbounds sd[i, j] = reinterpret(Float32, i32(b, k))
        k += 4
    end
    return sd
end
function glyph_sdf(font::Makie.NativeFont, cp::UInt64, px::Int, ds::Int, pad::Int)
    return parse_sdf(host_job(request("sdf", font, string("\n", cp, "\n", px, "\n", ds, "\n", pad))))
end

"The glyph `cp` of `font` at `px` pixels, from the host: `glyph_raster(font, codepoint, px) -> (bitmap, metrics)`."
function glyph_raster(font::Makie.NativeFont, cp::UInt64, px::Int)
    return parse_glyph(host_job(request("glyph", font, string("\n", cp, "\n", px))), true)
end
function glyph_extent(font::Makie.NativeFont, cp::UInt64, px::Int)
    return parse_glyph(host_job(request("extent", font, string("\n", cp, "\n", px))), false).extent
end

# (the pixel size the ink box of an extent is measured at: Makie's atlas renders glyphs at pix_per_glyph * downsample)
const EXTENT_PX = 64 * 5

Base.Experimental.@overlay WASM FTA.glyph_index(face::FTA.FTFont, c::Char) = UInt64(UInt32(c))
Base.Experimental.@overlay WASM function FTA.get_extent(face::FTA.FTFont, glyphspec)
    gi = FTA.glyph_index(face, glyphspec)
    return get!(FTA.get_cache(face), gi) do
        glyph_extent(face, gi, EXTENT_PX)
    end
end

# (texture_atlas.jl:239) the browser falls back to other fonts itself (Canvas2D's font stack): no fallback fonts here
Base.Experimental.@overlay WASM Makie.find_font_for_char(glyph::Char, font::Makie.NativeFont) = font
Base.Experimental.@overlay WASM Makie.find_font_for_char(glyph::Integer, font::Makie.NativeFont) = font
# (texture_atlas.jl:139) the program's atlas (empty at build time), not a cache that loads or renders one
Base.Experimental.@overlay WASM Makie.get_texture_atlas(resolution::Int, pix_per_glyph::Int) = ATLAS[]

@noinline no_bezier() = error("text: BezierPath markers are not supported in this build (they render through FreeType's outline API)")

"The existing glyph insertion (texture_atlas.jl:277-303), with the browser's finished SDF tile in place of FreeType's bitmap and Makie's SDF step."
function render_glyph(atlas::Makie.TextureAtlas, glyph_index::UInt64, font::Makie.NativeFont)
    downsample = atlas.downsample
    pad = atlas.glyph_padding
    pixelsize = atlas.pix_per_glyph
    cp = glyph_index == 0 ? UInt64(' ') : glyph_index      # (a newline and the like: a space, as Makie does)
    sd = glyph_sdf(font, cp, Int(pixelsize * downsample), Int(downsample), Int(pad))   # (= Makie.sdistancefield(bitmap, downsample, pad), texture_atlas.jl:331-353, computed by the host)
    rect = Rect2{Int32}(0, 0, size(sd)...)
    uv = push!(atlas.rectangle_packer, rect)
    isnothing(uv) && error("texture atlas is too small. Resizing not implemented yet.")
    atlas.data[uv.area] = sd
    # (`font_render_callback`s are GLMakie's: none in a browser program)
    return uv.area
end

Base.Experimental.@overlay WASM function Makie.insert_glyph!(atlas::Makie.TextureAtlas, hash::UInt32,
        path_or_glyp::Union{Makie.BezierPath, Tuple{UInt64, Makie.NativeFont}})
    return get!(atlas.mapping, hash) do
        path_or_glyp isa Makie.BezierPath && no_bezier()
        gi, font = path_or_glyp::Tuple{UInt64, Makie.NativeFont}
        uv_pixel = render_glyph(atlas, gi, font)
        tex_size = Vec2f(size(atlas))
        idx_left_bottom = minimum(uv_pixel)
        idx_right_top = maximum(uv_pixel)
        uv_left_bottom_pad = (idx_left_bottom .+ 0.5) ./ tex_size
        uv_right_top_pad = (idx_right_top .- 0.5) ./ tex_size
        uv_offset_rect = Makie.Vec4f(uv_left_bottom_pad..., uv_right_top_pad...)
        push!(atlas.uv_rectangles, uv_offset_rect)
        return length(atlas.uv_rectangles)
    end
end

end # BrowserGlyphsSDF
