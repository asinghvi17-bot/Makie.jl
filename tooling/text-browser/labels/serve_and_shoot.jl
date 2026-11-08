# VARIANT=native|c [ROT=1] [DPR=1]: serves the figure through WGLMakie/Bonito, and screenshots it with the browser (Playwright, from here)
using WGLMakie, Makie, Bonito
WGLMakie.activate!()
include(joinpath(ENV["TB"], "labels", "browser_labels.jl"))
include(joinpath(@__DIR__, "figure.jl"))
using .BrowserLabels
variant = ENV["VARIANT"]
kw = NamedTuple()
if variant == "c"
    m = BrowserLabels.TableMetrics(; fallback = false)
    BrowserLabels.load!(m, "metrics.tsv")
    BrowserLabels.METRICS[] = m
    fig = with_theme(() -> make_figure(; kw...), text_handler = BrowserLabels.Handler())
    Makie.update_state_before_display!(fig)
    labels, skipped = BrowserLabels.collect_labels(fig.scene)
    write("labels_$(get(ENV, "FIG", "plain"))_c.json", BrowserLabels.labels_json(labels, (600, 400)))
    modes = "none,dom,canvas"
else
    fig = make_figure(; kw...)
    modes = "none"
end
port = 8770 + (variant == "c" ? 1 : 0) + 2 * findfirst(==(get(ENV, "FIG", "plain")), ["plain", "extras", "scene3d"])
app = App() do session
    return Bonito.DOM.div(fig; style = "margin:0;padding:0;width:620px;height:430px;overflow:hidden;")
end
server = Bonito.Server(app, "127.0.0.1", port)
tag = string(get(ENV, "FIG", "plain"), "_", variant, get(ENV, "DPR", "1") == "1" ? "" : "_dpr" * ENV["DPR"])
try
    run(`node $(ENV["TB"])/labels/shoot.mjs http://127.0.0.1:$port/ $(variant == "c" ? "labels_" * get(ENV, "FIG", "plain") * "_c.json" : "-") shot_$tag $modes`)
finally
    close(server)
end
