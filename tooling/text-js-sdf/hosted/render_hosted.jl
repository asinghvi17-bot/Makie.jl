# VARIANT=native|bsdf FIG=text|axis HOST_TABLE=table.tsv HOST_MISSING=missing.txt [OUT=prefix]:
# serves the figure through WGLMakie/Bonito (native Julia) and screenshots it in headless Chromium. `bsdf`: the glyph atlas and extents are
# what B' (probes/browser_glyphs_sdf.jl, hosted: see hosted_bsdf.jl) builds from the browser's rasters and JS SDF tiles. Prints "still missing: n".
using WGLMakie, Makie, Bonito
WGLMakie.activate!()
include(joinpath(@__DIR__, "figures.jl"))
variant = ENV["VARIANT"]
fig = nothing
if variant == "bsdf"
    include(joinpath(@__DIR__, "hosted_bsdf.jl"))
    load_host_table!(get(ENV, "HOST_TABLE", "table.tsv"))
    mod = load_bsdf_hosted(joinpath(ENV["TJ"], "probes", "browser_glyphs_sdf.jl"))
    fonts = [Makie.to_font(FAMILY), Makie.to_font(FAMILY * " Bold"), Makie.to_font(FAMILY * " Italic"), Makie.to_font(FAMILY * " Bold Italic")]
    Base.invokelatest(mod.prepare!, fonts; resolution = 2048)
end
fig = make_figure()
Makie.update_state_before_display!(fig)
if variant == "bsdf"
    # what WGLMakie does when the page connects (`sync_glyphs!`): insert the plots' glyphs into the atlas. Done here, before serving,
    # so that the host jobs it needs are known (and answered) before the page is displayed.
    scene = fig isa Figure ? fig.scene : fig
    for p in Makie.collect_atomic_plots(scene)
        p isa Makie.Glyphs && Makie.get_glyph_data(Makie.get_texture_atlas(), Set{UInt32}(), p.glyph_indices[], p.font[])
    end
    n = Base.invokelatest(write_missing, get(ENV, "HOST_MISSING", "missing.txt"))
    println("still missing: ", n, " (host jobs ", HOST_JOBS[], ", atlas entries ", length(Main.BrowserGlyphsSDF.ATLAS[].uv_rectangles), ")")
    n == 0 || exit(0)
end
port = 8790 + (variant == "bsdf" ? 1 : 0) + 2 * (get(ENV, "FIG", "text") == "axis" ? 1 : 0)
app = App() do session
    return Bonito.DOM.div(fig; style = "margin:0;padding:0;width:620px;height:430px;overflow:hidden;")
end
server = Bonito.Server(app, "127.0.0.1", port)
try
    run(`node $(ENV["TJ"])/browser/shoot.mjs http://127.0.0.1:$port/ $(get(ENV, "OUT", "shot"))_$(get(ENV, "FIG", "text"))_$variant`)
finally
    close(server)
end
