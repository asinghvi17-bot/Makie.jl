# The figures of the B' image comparison (FIG=text|axis). `text`: a bare scene of text! plots (the kind of program probes/p_Bsdf_text.jl
# compiles); `axis`: an Axis with tick labels, title and axis labels.
const FAMILY = "TeX Gyre Heros Makie"
function make_figure(kind = get(ENV, "FIG", "text"))
    if kind == "text"
        scene = Scene(size = (600, 260), camera = campixel!, backgroundcolor = :white)
        text!(scene, Point2f(10, 205); text = "Wasm: ünï 42 ΩΣ ≈ ∞", fontsize = 40, color = :black)
        text!(scene, Point2f(10, 160); text = "The quick brown fox jumps over", fontsize = 24, color = :red)
        text!(scene, Point2f(10, 125); text = "0123456789 !\"#\$%&'()*+,-./:;<=>?@", fontsize = 18, color = :black)
        text!(scene, Point2f(10, 90); text = "Bold face", fontsize = 22, font = :bold, color = :blue)
        text!(scene, Point2f(150, 90); text = "Italic face", fontsize = 22, font = :italic, color = :darkgreen)
        text!(scene, Point2f(10, 55); text = "small text 12 px, 11 px", fontsize = 12, color = :black)
        text!(scene, Point2f(10, 20); text = "rotated", fontsize = 16, rotation = pi / 12, color = :purple)
        return scene
    elseif kind == "axis"
        fig = Figure(size = (600, 400), figure_padding = 10)
        ax = Axis(fig[1, 1]; title = "Browser glyphs: Axis title", xlabel = "time (s)", ylabel = "amplitude")
        xs = range(0, 10, length = 100)
        lines!(ax, xs, sin.(xs); linewidth = 2)
        lines!(ax, xs, cos.(xs); linewidth = 2, color = :red)
        return fig
    end
    error("FIG = ", kind)
end
