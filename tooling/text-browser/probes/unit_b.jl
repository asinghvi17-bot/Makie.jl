using Makie, WasmCodegen
include("browser_glyphs.jl")
using .BrowserGlyphs
font = Makie.to_font("TeX Gyre Heros Makie")
BrowserGlyphs.prepare!([font])
function le(v...) b = UInt8[]; for x in v; append!(b, reinterpret(UInt8, [Int32(x)])); end; b end
BrowserGlyphs.host_job(req::String) = occursin("\nfont\n", req) ? le(1, 0, 947000, -218000, 1165000) :
    vcat(le(1, 0, 3, 2, 1, 2, 556000, 100000, 700000, 400000, 500000), UInt8[1,2,3,4,5,6])
@show BrowserGlyphs.info(font)
r = BrowserGlyphs.glyph_raster(font, UInt64('a'), 320)
@show size(r.bitmap) r.extent
@show BrowserGlyphs.glyph_extent(font, UInt64('a'), 320)
@show BrowserGlyphs.request("glyph", font, "\n97\n320")
