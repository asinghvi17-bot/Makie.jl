# Native reference for the SDF comparison: FreeType's 320 px bitmaps (what Makie's atlas renders), Makie's own
# `sdistancefield(bitmap, 5, 12)` tiles for them, and the native per-glyph times of both steps.
# julia --project=ENV sdf_ref.jl OUT.json
using Makie, Base64
import FreeTypeAbstraction as FTA
font = Makie.to_font("TeX Gyre Heros Makie")
chars = vcat(collect(Char(32):Char(126)), collect("ΩαβγδΣπ°±×éüñ–—•…≤≥∞"))
atlas = Makie.TextureAtlas()       # (the default atlas settings: pix_per_glyph 64, padding 12, downsample 5)
ds, pad, px = Int(atlas.downsample), Int(atlas.glyph_padding), Int(atlas.pix_per_glyph * atlas.downsample)
f32bytes(m) = collect(reinterpret(UInt8, vec(Float32.(m))))
# warm up
let gi = FTA.glyph_index(font, 'g'); bm, _ = FTA.renderface(font, gi, px); Makie.sdistancefield(bm, ds, pad); end
io = IOBuffer()
print(io, "{\"px\":", px, ",\"downsample\":", ds, ",\"pad\":", pad, ",\"glyphs\":[")
global isfirst = true
t_render = Float64[]; t_sdf = Float64[]
for c in chars
    gi = FTA.glyph_index(font, c)
    gi == 0 && continue
    tr = @elapsed ((bm, ext) = FTA.renderface(font, gi, px))
    ts = @elapsed (sd = Makie.sdistancefield(bm, ds, pad))
    push!(t_render, tr); push!(t_sdf, ts)
    global isfirst
    isfirst || print(io, ","); isfirst = false
    print(io, "{\"c\":", Int(c), ",\"bw\":", size(bm, 1), ",\"bh\":", size(bm, 2), ",\"tw\":", size(sd, 1), ",\"th\":", size(sd, 2),
          ",\"bmp\":\"", base64encode(vec(bm)), "\",\"sdf\":\"", base64encode(f32bytes(sd)), "\"}")   # bitmap (width, rows) with x fastest, i.e. row-major as FreeType; tile x fastest
end
print(io, "],\"native_render_ms\":", 1000 * sum(t_render) / length(t_render), ",\"native_sdf_ms\":", 1000 * sum(t_sdf) / length(t_sdf),
      ",\"native_sdf_ms_median\":", 1000 * sort(t_sdf)[end ÷ 2], ",\"n\":", length(t_sdf), "}")
write(ARGS[1], take!(io))
println("wrote ", filesize(ARGS[1]), " bytes; mean render ", round(1000 * sum(t_render) / length(t_render); digits = 2), " ms, mean sdistancefield ", round(1000 * sum(t_sdf) / length(t_sdf); digits = 2), " ms, n=", length(t_sdf))
