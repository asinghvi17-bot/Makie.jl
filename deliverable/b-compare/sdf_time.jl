using Makie
import FreeTypeAbstraction as FTA
f = Makie.to_font("TeX Gyre Heros Makie")
bm, _ = FTA.renderface(f, FTA.glyph_index(f, 'g'), 320)
Makie.sdistancefield(bm, 5, 12)
t = minimum(@elapsed(Makie.sdistancefield(bm, 5, 12)) for _ in 1:5)
println("bitmap ", size(bm), " sdistancefield native: ", round(t * 1000; digits = 1), " ms")
