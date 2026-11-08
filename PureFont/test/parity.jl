# Parity of PureFont against FreeTypeAbstraction (native only):
#   julia --project=<env with Makie, FreeTypeAbstraction, PureFont> test/parity.jl
using PureFont, FreeTypeAbstraction, Makie, Statistics, Printf
const FTA = FreeTypeAbstraction

const FONTDIR = Makie.assetpath("fonts")
const CHARSET = vcat(collect(Char(32):Char(126)), collect(Char(160):Char(255)), collect(Char(0x391):Char(0x3c9)))

function extent_of(m::PureFont.GlyphMetrics, upem)
    s = Float32(upem)
    return FTA.FontExtent{Float32}(
        FTA.Vec{2, Float32}(Float32(m.vert_bearing_x), Float32(m.vert_bearing_y)) ./ s,
        FTA.Vec{2, Float32}(Float32(m.hori_bearing_x), Float32(m.hori_bearing_y)) ./ s,
        FTA.Vec{2, Float32}(Float32(m.hori_advance), Float32(m.vert_advance)) ./ s,
        FTA.Vec{2, Float32}(Float32(m.width), Float32(m.height)) ./ s)
end

function metrics_parity(pf, ft; allglyphs = true)
    bad = 0; total = 0
    ids = allglyphs ? (0:pf.num_glyphs - 1) : [PureFont.glyph_index(pf, c) for c in CHARSET]
    for gid in ids
        total += 1
        e = FTA.get_extent(ft, UInt64(gid))
        m = PureFont.glyph_metrics(pf, gid)
        if extent_of(m, pf.units_per_em) != e
            bad += 1
            bad <= 3 && println("  metrics mismatch gid $gid: $m vs $e")
        end
    end
    return bad, total
end

# FreeType's render of `gid` at `size` px with the given FT_LOAD flags (hinting on unless FT_LOAD_NO_HINTING)
function ft_render(ft, gid, size; nohint = false)
    FTA.set_pixelsize(ft, size)
    flags = FTA.FreeType.FT_LOAD_RENDER | (nohint ? FTA.FreeType.FT_LOAD_NO_HINTING : 0)
    err = FTA.FreeType.FT_Load_Glyph(ft, UInt64(gid), flags)
    err == 0 || error("FT_Load_Glyph $err")
    gl = unsafe_load(ft.glyph)
    return FTA.glyphbitmap(gl.bitmap)
end

function bitmap_parity(pf, ft, gids; pixel_size = 320, nohint = false)
    nsize = 0; maxdiff = 0; sumdiff = 0.0; npix = 0; nglyph = 0
    for gid in gids
        gid == 0 && continue
        bmp_ft = ft_render(ft, gid, pixel_size; nohint)
        bmp, left, top = PureFont.render_glyph(pf, gid, pixel_size)
        nglyph += 1
        if size(bmp) != size(bmp_ft)
            nsize += 1
            nsize <= 3 && println("  bitmap size mismatch gid $gid: $(size(bmp)) vs $(size(bmp_ft))")
            continue
        end
        d = abs.(Int.(bmp) .- Int.(bmp_ft))
        maxdiff = max(maxdiff, maximum(d; init = 0)); sumdiff += sum(d); npix += length(d)
    end
    return (; nglyph, nsize, maxdiff, meandiff = sumdiff / max(npix, 1))
end

function sdf_parity(pf, ft, gids; pixel_size = 64, downsample = 5, pad = 12, nohint = false)
    maxd = 0.0f0; sumd = 0.0; n = 0; nsize = 0; band_sum = 0.0; band_n = 0; nglyph = 0
    for gid in gids
        gid == 0 && continue
        bmp_ft = ft_render(ft, gid, pixel_size * downsample; nohint)
        bmp, _, _ = PureFont.render_glyph(pf, gid, pixel_size * downsample)
        isempty(bmp_ft) && continue
        nglyph += 1
        size(bmp) == size(bmp_ft) || (nsize += 1; continue)
        s1 = Makie.sdistancefield(bmp_ft, downsample, pad)
        s2 = Makie.sdistancefield(bmp, downsample, pad)
        d = abs.(s1 .- s2)
        maxd = max(maxd, maximum(d)); sumd += sum(d); n += length(d)
        band = abs.(s1) .< 2
        band_sum += sum(d[band]); band_n += count(band)
    end
    return (; nglyph, nsize, max = maxd, mean = sumd / max(n, 1), mean_near_edge = band_sum / max(band_n, 1))
end

function main()
    for (file, ftname) in [("TeXGyreHerosMakie-Regular.otf", "TeX Gyre Heros Makie"),
                           ("TeXGyreHerosMakie-Bold.otf", "TeX Gyre Heros Makie Bold"),
                           ("DejaVuSans.ttf", nothing)]
        path = joinpath(FONTDIR, file)
        pf = PureFont.Font(path)
        ft = ftname === nothing ? FTA.try_load(path) : Makie.to_font(ftname)
        println("== ", file, " ", pf)
        println("  face metrics: ", (pf.units_per_em, pf.ascender, pf.descender, pf.height), " vs ",
                (Int(ft.units_per_EM), Int(ft.ascender), Int(ft.descender), Int(ft.height)))
        # cmap parity over the test set + metrics
        cm_bad = count(c -> PureFont.glyph_index(pf, c) != FTA.glyph_index(ft, c), CHARSET)
        println("  cmap mismatches over the ASCII/Latin-1/Greek set: ", cm_bad, " of ", length(CHARSET))
        b, t = metrics_parity(pf, ft; allglyphs = true)
        println("  metrics (all glyphs): $b mismatches of $t")
        b, t = metrics_parity(pf, ft; allglyphs = false)
        println("  metrics (test set): $b mismatches of $t")
        gids = [PureFont.glyph_index(pf, c) for c in CHARSET]
        println("  bitmap @320px: ", bitmap_parity(pf, ft, gids))
        println("  SDF: ", sdf_parity(pf, ft, gids))
        println("  bitmap @320px vs FT_LOAD_NO_HINTING: ", bitmap_parity(pf, ft, gids; nohint = true))
        println("  SDF vs FT_LOAD_NO_HINTING: ", sdf_parity(pf, ft, gids; nohint = true))
    end
end
main()
