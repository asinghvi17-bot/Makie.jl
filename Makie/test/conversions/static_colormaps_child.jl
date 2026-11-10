# Run by named_colormaps.jl in a project whose LocalPreferences.toml sets
#   [Makie]
#   static_colormaps = ["magma", "Set1", "Accent", "Spectral"]
# so that Makie was precompiled with the static colormap tables.
using Test
using Makie
using Makie: Reverse, RGBAf, to_colormap, categorical_colors

include(joinpath(@__DIR__, "named_colormaps_reference.jl")) # registry_colormap, outcome

@testset "static_colormaps preference" begin
    @test Makie.static_colormaps_enabled
    @test Makie.static_colormap_names == ["Accent", "Set1", "Spectral", "magma", "viridis"]
    table = Makie.static_colormaps
    @test Set(keys(table.colormaps)) == Set(Makie.static_colormap_names)
    @test Set(keys(table.colorbrewer_palettes)) == Set(["Accent", "Set1", "Spectral"])

    for name in Makie.static_colormap_names
        expected = registry_colormap(name)
        @test @inferred(to_colormap(Symbol(name))) == expected
        @test to_colormap(name) == expected
        @test to_colormap(Reverse(name)) == reverse(expected)
        @test to_colormap(Reverse(Symbol(name))) == reverse(expected)
        @test to_colormap((name, 0.25)) == RGBAf.(Makie.ColorTypes.color.(expected), Makie.ColorTypes.alpha.(expected) .* 0.25)
        @test to_colormap((Reverse(Symbol(name)), 0.5)) == RGBAf.(Makie.ColorTypes.color.(reverse(expected)), Makie.ColorTypes.alpha.(reverse(expected)) .* 0.5)
        @test to_colormap(Symbol(name)) !== to_colormap(Symbol(name))
    end
    @test Base.return_types(to_colormap, (Symbol,)) == [Vector{RGBAf}]
    @test Base.return_types(to_colormap, (String,)) == [Vector{RGBAf}]
    @test Base.return_types(to_colormap, (Reverse{Symbol},)) == [Vector{RGBAf}]
    @test Base.return_types(to_colormap, (Tuple{Symbol, Float64},)) == [Vector{RGBAf}]
    @test Base.return_types(categorical_colors, (Symbol, Int)) == [Vector{RGBAf}]

    # the same as the lookups in the registry give
    for name in ("Set1", "Accent", "Spectral"), n in 0:14
        expected = outcome(() -> brewer_palette(name, n))
        @test outcome(() -> categorical_colors(name, n)) == expected
        @test outcome(() -> categorical_colors(Symbol(name), n)) == expected
    end
    @test categorical_colors(:magma, 4) == categorical_colors(registry_colormap("magma"), 4)
    @test categorical_colors("magma", 400, true) == categorical_colors(registry_colormap("magma"), 400, true)
    @test Makie.Palette(:Set1, 4).colors == categorical_colors(:Set1, 4)

    # colormaps that aren't in the tables
    for f in (() -> to_colormap(:inferno), () -> to_colormap(Reverse(:inferno)), () -> to_colormap(("inferno", 0.5)), () -> categorical_colors(:inferno, 3), () -> categorical_colors("Set2", 3))
        err = try
            f()
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("is not in Makie's static colormap tables", err.msg)
        @test occursin("Makie.set_static_colormaps!(\"", err.msg)
    end
    @test_throws "The colormap `inferno` is not" to_colormap(:inferno)
    @test_throws "The colormap `Set2` is not" categorical_colors(:Set2, 3)

    # the plots take their colors from the tables
    f, ax, pl = heatmap(rand(4, 4); colormap = :magma)
    @test pl.raw_colormap[] == registry_colormap("magma")
    f, ax, pl = heatmap(rand(4, 4); colormap = Reverse(:Spectral))
    @test pl.raw_colormap[] == reverse(registry_colormap("Spectral"))
end
