# julia --project=ENV native.jl PROG.jl — the same program natively (FreeType unless PF_NATIVE=pure), with timing of new glyphs
using Makie, PureFont, WasmCodegen
include(joinpath(@__DIR__, "font_overrides.jl"))
include(abspath(ARGS[1]))
Prog.prepare()
rc = Prog.main()
write(Core.stdout, "\n[main returned $rc]\n")
if length(ARGS) > 1 && ARGS[2] == "time"
    n = Int(Prog.ncp())
    Prog.glyph(Prog.nth_cp(Int32(0)))   # (warm up: compiles)
    t = @elapsed for i in 1:n - 1
        Prog.glyph(Prog.nth_cp(Int32(i)))
    end
    write(Core.stdout, string("native: ", round(1000 * t / (n - 1); digits = 3), " ms per new glyph (", n - 1, " glyphs)\n"))
    for (name, f) in (("rasterize", Prog.bench_raster), ("rasterize + SDF", Prog.bench_sdf))
        f(Prog.nth_cp(Int32(0)))
        t = @elapsed for i in 1:n - 1
            f(Prog.nth_cp(Int32(i)))
        end
        write(Core.stdout, string("native: ", name, " ", round(1000 * t / (n - 1); digits = 3), " ms per glyph\n"))
    end
end
