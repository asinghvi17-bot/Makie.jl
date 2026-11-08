# Native reference: FreeType's metrics and 320 px bitmaps (Makie's atlas render size) for TeX Gyre Heros Makie
using Makie, Base64
import FreeTypeAbstraction as FTA
font = Makie.to_font("TeX Gyre Heros Makie")
chars = vcat(collect(Char(32):Char(126)), collect("ΩαβγδΣπ°±×éüñ–—•…≤≥∞"))
PX = 64 * 5
io = IOBuffer()
print(io, "{\"font\":\"TeX Gyre Heros Makie\",\"upem\":", font.units_per_EM, ",\"ascender\":", font.ascender, ",\"descender\":", font.descender,
      ",\"height\":", font.height, ",\"px\":", PX, ",\"glyphs\":[")
isfirst = true
for c in chars
    gi = FTA.glyph_index(font, c)
    gi == 0 && continue
    ext = FTA.get_extent(font, gi)              # unhinted, em-normalized (FT_LOAD_NO_SCALE)
    gl = FTA.loadglyph(font, gi, PX)
    bm = FTA.glyphbitmap(gl.bitmap)             # (width, rows) UInt8
    isfirst || print(io, ","); global isfirst = false
    print(io, "{\"c\":", Int(c), ",\"gi\":", gi,
          ",\"adv\":", FTA.hadvance(ext), ",\"bx\":", FTA.hbearing_ori_to_left(ext), ",\"by\":", FTA.hbearing_ori_to_top(ext),
          ",\"w\":", FTA.inkwidth(ext), ",\"h\":", FTA.inkheight(ext),
          ",\"left\":", gl.bitmap_left, ",\"top\":", gl.bitmap_top, ",\"bw\":", size(bm, 1), ",\"bh\":", size(bm, 2),
          ",\"hadv_px\":", gl.metrics.horiAdvance / 64,
          ",\"bmp\":\"", base64encode(vec(bm)), "\"}")   # row-major
end
print(io, "]}")
write(joinpath(@__DIR__, "ft_ref.json"), take!(io))
println("wrote ", filesize(joinpath(@__DIR__, "ft_ref.json")), " bytes")
cp(joinpath(Makie.assetpath("fonts"), "TeXGyreHerosMakie-Regular.otf"), joinpath(@__DIR__, "TeXGyreHerosMakie-Regular.otf"); force = true)
