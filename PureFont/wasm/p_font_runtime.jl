# Runtime glyphs: text in any runtime string is laid out against PureFont's metrics and rendered into the atlas
# the first time a glyph is used. Entry points: `main` (a fixed text, printed), `glyph(cp)`, `glyph_bold(cp)`
# (one new code point; for timing from the host), `text(n)` (n code points from U+00A0 on).
# PF_PREBUILT=1 ships a prerendered atlas (printable ASCII of both fonts); otherwise the atlas is created at run time.
module Prog
using Makie, PureFont
import FreeTypeAbstraction as FTA
using ..PureFontOverrides

const FONT = Makie.to_font("TeX Gyre Heros Makie")
const BOLD = Makie.to_font("TeX Gyre Heros Makie Bold")
const CONFIG = (;)
out(s::AbstractString) = (write(Core.stdout, s); nothing)
# (`ErrorException.msg` is an AbstractString: only a String message is printed, as in the capmap probes)
function describe(@nospecialize(e))::String
    if e isa ErrorException
        m = e.msg
        return m isa String ? string("ErrorException: ", m) : "ErrorException"
    end
    return "another exception type"
end

"Put `c` in the atlas (rendering it if new) and describe what Makie then sees: extent, uv rectangle and SDF checksum."
function glyph_line(font::FTA.FTFont, c::Char)::String
    atlas = Makie.get_texture_atlas()
    uv = Makie.glyph_uv_width!(atlas, c, font)
    gi = FTA.glyph_index(font, c)
    ext = FTA.get_extent(font, c)
    xr, yr = Makie.sdf_uv_to_pixel(atlas, uv)
    s = 0.0
    for y in yr, x in xr
        s += Float64(atlas.data[x, y])
    end
    return string(UInt32(c), " g=", gi, " adv=", round(Float64(ext.advance[1]); digits = 4),
                  " ink=", round(Float64(ext.scale[1]); digits = 4), "x", round(Float64(ext.scale[2]); digits = 4),
                  " bear=", round(Float64(ext.horizontal_bearing[1]); digits = 4), ",", round(Float64(ext.horizontal_bearing[2]); digits = 4),
                  " uv=", round(Float64(uv[1]); digits = 4), ",", round(Float64(uv[2]); digits = 4), ",", round(Float64(uv[3]); digits = 4), ",", round(Float64(uv[4]); digits = 4),
                  " rect=", length(xr), "x", length(yr), " sdf=", round(s; digits = 1), "\n")
end

const TEXT = "Wasm 1.25 {ok}! Wörld ÀÉÎ αβγ ΩΣ ñ ß ©"
const TEXT_BOLD = "Bold Ω ß"
# code points the font has and `main` does not use: new glyphs to time (computed natively at build time, FreeType)
const TIMING = Int32[Int32(c) for c in vcat(Char(0xa1):Char(0xff), Char(0x100):Char(0x17f), Char(0x391):Char(0x3c9))
                     if FTA.glyph_index(FONT, c) != 0 && !(c in TEXT)]
nth_cp(i::Int32)::Int32 = TIMING[Int(i) + 1]
ncp()::Int32 = Int32(length(TIMING))

function main()::Int32
    try
        out("font: " * FONT.family_name * " / " * FONT.style_name * " upem=" * string(Int(FONT.units_per_EM)) * " asc=" * string(Int(FONT.ascender)) * " desc=" * string(Int(FONT.descender)) * " h=" * string(Int(FONT.height)) * "\n")
        for c in TEXT
            out(glyph_line(FONT, c))
        end
        for c in TEXT_BOLD
            out(glyph_line(BOLD, c))
        end
        atlas = Makie.get_texture_atlas()
        out(string("atlas glyphs: ", length(atlas.uv_rectangles), "\n"))
        return Int32(0)
    catch e
        out(string("EXCEPTION: ", describe(e), "\n"))
        return Int32(1)
    end
end

# (new glyph for the host to time: the checksum is the rect area, so nothing is optimised away)
function glyph(cp::Int32)::Int32
    atlas = Makie.get_texture_atlas()
    uv = Makie.glyph_uv_width!(atlas, Char(cp), FONT)
    return Int32(length(atlas.uv_rectangles)) + Int32(round(1000 * (uv[3] - uv[1])))
end
function glyph_bold(cp::Int32)::Int32
    atlas = Makie.get_texture_atlas()
    uv = Makie.glyph_uv_width!(atlas, Char(cp), BOLD)
    return Int32(length(atlas.uv_rectangles)) + Int32(round(1000 * (uv[3] - uv[1])))
end
"Layout width (sum of advances in 1/1000 em) of `n` consecutive code points from U+00A0: metrics only, no rendering."
function advance_sum(n::Int32)::Int32
    s = 0.0f0
    for i in 0:Int(n) - 1
        c = Char(0x00a0 + i)
        FTA.glyph_index(FONT, c) == 0 && continue
        s += FTA.get_extent(FONT, c).advance[1]
    end
    return Int32(round(1000 * s))
end
# (where a new glyph's time goes: the rasterizer alone, then with Makie's SDF step)
function bench_raster(cp::Int32)::Int32
    atlas = Makie.get_texture_atlas()
    f = PureFontOverrides.FONTS[FONT]
    bmp, _, _ = PureFont.render_glyph(f, PureFont.glyph_index(f, Char(cp)), Int(atlas.pix_per_glyph) * Int(atlas.downsample))
    return Int32(length(bmp))
end
function bench_sdf(cp::Int32)::Int32
    atlas = Makie.get_texture_atlas()
    f = PureFontOverrides.FONTS[FONT]
    bmp, _, _ = PureFont.render_glyph(f, PureFont.glyph_index(f, Char(cp)), Int(atlas.pix_per_glyph) * Int(atlas.downsample))
    sd = Makie.sdistancefield(bmp, Int(atlas.downsample), Int(atlas.glyph_padding))
    return Int32(length(sd))
end
const ENTRIES = [(bench_raster, (Int32,), "bench_raster"), (bench_sdf, (Int32,), "bench_sdf"), (main, (), "main"), (nth_cp, (Int32,), "nth_cp"), (ncp, (), "ncp"), (glyph, (Int32,), "glyph"), (glyph_bold, (Int32,), "glyph_bold"), (advance_sum, (Int32,), "advance_sum")]

function prepare()
    PureFontOverrides.register!(FONT, BOLD)
    if get(ENV, "PF_PREBUILT", "0") == "1"
        PureFontOverrides.prebuild_atlas!(Char(32):Char(126), FONT, BOLD)
    end
    # (native runs, `PF_NATIVE=ft|pure`: FreeType, the reference, or PureFont installed natively; both start from an
    # empty atlas, not Makie's cached one, so that the glyphs are rendered here)
    nat = get(ENV, "PF_NATIVE", "")
    nat == "pure" && PureFontOverrides.install_native!()
    nat == "ft" && (Makie.TEXTURE_ATLASES[(2048, 64)] = Makie.TextureAtlas(; resolution = 2048, pix_per_glyph = 64))
    return
end
end
