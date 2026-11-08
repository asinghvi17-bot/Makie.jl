# one pass of the label pipeline (native): the figure with the browser-metrics handler, its label list, and the measurements it still needs
using WGLMakie, Makie
include(joinpath(ENV["TB"], "labels", "browser_labels.jl"))
include(joinpath(@__DIR__, "figure.jl"))
using .BrowserLabels
m = BrowserLabels.TableMetrics(; fallback = get(ENV, "FALLBACK", "1") == "1")
isfile("metrics.tsv") && BrowserLabels.load!(m, "metrics.tsv")
BrowserLabels.METRICS[] = m
fig = with_theme(text_handler = BrowserLabels.Handler()) do
    make_figure()
end
Makie.update_state_before_display!(fig)
labels, skipped = BrowserLabels.collect_labels(fig.scene)
println(length(labels), " labels; skipped ", skipped)
for l in labels
    println(rpad(l.text, 28), " x=", round(l.x; digits = 1), " y=", round(l.y; digits = 1), " size=", l.size, " angle=", round(l.angle; digits = 3), " w=", round(l.width; digits = 2))
end
write("labels_$(get(ENV, "FIG", "plain"))_pass.json", BrowserLabels.labels_json(labels, (600, 400)))
n = BrowserLabels.write_missing(m, "missing.tsv")
println("still missing: ", n)
