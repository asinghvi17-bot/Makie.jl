# What the registry lookups of `to_colormap` and `categorical_colors` return, written out independently of them.
function registry_colormap(name::AbstractString)
    return if name in Makie.colorbrewer_8color_names
        Makie.to_colormap(Makie.ColorBrewer.palette(name, 8))
    else
        Makie.to_colormap(Makie.PlotUtils.get_colorscheme(Symbol(name)))
    end
end

brewer_palette(name::AbstractString, n::Integer) = Makie.to_colormap(Makie.ColorBrewer.palette(name, n))

# the value, or the type and message of the error, so that errors are compared too
outcome(f) = try
    f()
catch e
    e isa ArgumentError || e isa ErrorException ? (typeof(e), e.msg) : rethrow()
end
