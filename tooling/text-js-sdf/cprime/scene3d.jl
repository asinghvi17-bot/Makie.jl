# VARIANT=native|sprite : an LScene with an opaque sphere and three labels. native: Makie text (markerspace = :pixel). sprite: no text plots; the page adds
# canvas-texture sprites (label_sprites.mjs) for the same labels. Served through WGLMakie/Bonito, screenshots by cprime/run_cprime.mjs.
using WGLMakie, Makie, Bonito
WGLMakie.activate!()
variant = ENV["VARIANT"]
const LABELS = [("inside the sphere", Point3f(0, 0, 0), :center, :black, 22), ("beyond the edge", Point3f(0.95, 0, 0.35), :left, :black, 22), ("above", Point3f(0, 0, 1.5), :center, :blue, 20)]
fig = Figure(size = (600, 400), figure_padding = 10)
sc = LScene(fig[1, 1]; show_axis = false)
mesh!(sc, Sphere(Point3f(0), 1.0f0); color = :orange)
# (the text plots' anchors are part of the scene's data limits, hence of the default camera: the sprite variant gets invisible points at the same anchors, so that both cameras are equal)
if variant == "sprite"
    scatter!(sc, [l[2] for l in LABELS]; markersize = 1, color = RGBAf(0, 0, 0, 0), markerspace = :pixel)
else
    for (t, p, h, c, fs) in LABELS
        text!(sc, p; text = t, fontsize = fs, align = (h, :center), color = c, markerspace = :pixel)
    end
end
port = 8810
app = App() do session
    return Bonito.DOM.div(fig; style = "margin:0;padding:0;width:620px;height:430px;overflow:hidden;")
end
server = Bonito.Server(app, "127.0.0.1", port)
try
    run(`node $(ENV["TJ"])/cprime/run_cprime.mjs http://127.0.0.1:$port/ $variant $(ENV["OUT"])`)
finally
    close(server)
end
