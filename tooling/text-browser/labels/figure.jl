# the figures of the C evaluation (FIG=plain|extras|scene3d)
function make_figure(; kwargs...)
    kind = get(ENV, "FIG", "plain")
    if kind == "plain"
        fig = Figure(size = (600, 400), figure_padding = 10)
        ax = Axis(fig[1, 1]; title = "Browser text: Axis title", xlabel = "time (s)", ylabel = "amplitude", kwargs...)
        xs = range(0, 10, length = 100)
        lines!(ax, xs, sin.(xs); linewidth = 2)
        lines!(ax, xs, cos.(xs); linewidth = 2, color = :red)
        return fig
    elseif kind == "extras"
        # rotated tick labels, a two-line centred title, LaTeX and rich text labels, a stroked text: what the label list can and cannot do
        fig = Figure(size = (600, 400), figure_padding = 10)
        ax = Axis(fig[1, 1]; title = "Two lines\nof title", titlealign = :center, xlabel = L"\sqrt{x^2 + 1}", ylabel = rich("y", subscript("i"), " (rich)"),
                  xticklabelrotation = pi / 4, xticks = 0:2:10)
        xs = range(0, 10, length = 100)
        lines!(ax, xs, sin.(xs); linewidth = 2)
        text!(ax, 5, 0.0; text = "stroked", fontsize = 22, color = :white, strokecolor = :black, strokewidth = 2, align = (:center, :center))
        text!(ax, 8, -0.8; text = "rotated 30°", rotation = pi / 6, fontsize = 16, color = :purple)
        return fig
    elseif kind == "scene3d"
        fig = Figure(size = (600, 400), figure_padding = 10)
        sc = LScene(fig[1, 1]; show_axis = false)
        mesh!(sc, Sphere(Point3f(0), 1.0f0); color = :orange)
        text!(sc, Point3f(0, 0, 0); text = "inside the sphere", fontsize = 24, align = (:center, :center), color = :black, markerspace = :pixel)
        text!(sc, Point3f(0, 0, 1.6); text = "above", fontsize = 20, align = (:center, :bottom), color = :blue, markerspace = :pixel)
        return fig
    end
    error("FIG = ", kind)
end
