using Makie: Reverse, record_colormaps

@testset "record_colormaps" begin
    @testset "names looked up while f runs" begin
        names = record_colormaps() do
            to_colormap(:magma)
            to_colormap("Set1")
            to_colormap(Reverse(:inferno))
            to_colormap((:plasma, 0.5))
            categorical_colors(:Accent, 3)
            categorical_colors("cividis", 4)
            to_colormap([RGBf(1, 0, 0), RGBf(0, 0, 1)]) # not a name
            nothing
        end
        @test names == ["Accent", "Set1", "cividis", "inferno", "magma", "plasma"]
        @test record_colormaps(() -> nothing) == String[]
        @test Makie.colormap_recording[] === nothing
        # only while it runs
        to_colormap(:magma)
        @test record_colormaps(() -> to_colormap(:turbo)) == ["turbo"]
    end

    @testset "names chosen at run time" begin
        choices = ["batlow", "RdBu", "magma"]
        @test record_colormaps(() -> foreach(c -> to_colormap(Symbol(c)), choices)) == sort(choices)
    end

    @testset "unknown names are not recorded, errors are passed on" begin
        @test_throws "There is no color gradient named not_a_gradient" record_colormaps(() -> (to_colormap(:magma); to_colormap(:not_a_gradient)))
        @test Makie.colormap_recording[] === nothing
        @test record_colormaps(() -> try to_colormap(:not_a_gradient) catch end) == String[]
    end

    @testset "nested" begin
        inner = String[]
        outer = record_colormaps() do
            to_colormap(:magma)
            append!(inner, record_colormaps(() -> to_colormap(:inferno)))
        end
        @test inner == ["inferno"]
        @test outer == ["inferno", "magma"]
    end

    @testset "plots, which compute their colormaps lazily" begin
        # f doesn't display (or return) the figure, the colormaps are computed anyway
        names = record_colormaps() do
            f = Figure()
            ax = Axis(f[1, 1])
            heatmap!(ax, rand(4, 4); colormap = :magma)
            scatter!(ax, rand(3), rand(3); color = 1:3, colormap = Reverse(:inferno))
            lines!(ax, rand(3); color = rand(3), colormap = (:plasma, 0.5))
            contourf(f[1, 2], rand(5, 5); colormap = :batlow)
            barplot!(ax, 1:3, rand(3); color = categorical_colors(:Set1, 3))
            scatter!(ax, rand(3); color = :red) # not a colormap
            nothing
        end
        @test names ⊇ ["Set1", "batlow", "inferno", "magma", "plasma"]
        @test names ⊆ ["Set1", "batlow", "inferno", "magma", "plasma", Makie.static_default_colormaps...]
        @test Makie.colormap_recording[] === nothing

        # the default colormap of a plot without one, and a Colorbar's
        @test "viridis" in record_colormaps(() -> (heatmap(rand(3, 3)); nothing))
        names = record_colormaps(() -> (f = Figure(); Colorbar(f[1, 1]; colormap = :cividis); nothing))
        @test "cividis" in names

        # a colormap chosen at run time, and one set after the plot was made
        names = record_colormaps() do
            for name in (:magma, :turbo)
                heatmap(rand(3, 3); colormap = name)
            end
            f, ax, pl = heatmap(rand(3, 3); colormap = :magma)
            pl.colormap = :Blues
            nothing
        end
        @test names ⊇ ["Blues", "magma", "turbo"]
    end

    @testset "with the static tables (as with the static_colormaps preference)" begin
        table = Makie.StaticColormaps(["viridis", "magma", "Set1"])
        magma, set1, viridis = to_colormap(:magma), categorical_colors(:Set1, 3), to_colormap(:viridis)
        names = record_colormaps() do
            # in the tables
            @test Makie.static_to_colormap(table, :magma) == magma
            @test Makie.static_categorical_colors(table, :Set1, 3, false) == set1
            # not in the tables: recorded, and replaced by the default colormap, so that the rest of the program runs
            @test Makie.static_to_colormap(table, :inferno) == viridis
            @test Makie.static_categorical_colors(table, "Set2", 3, false) == viridis[1:3]
            @test Makie.static_categorical_colors(table, :Accent, 300, false) == viridis[mod1.(1:300, end)]
            # not a colormap
            @test_throws "The colormap `not_a_gradient` is not" Makie.static_to_colormap(table, :not_a_gradient)
        end
        @test names == ["Accent", "Set1", "Set2", "inferno", "magma"]
        # not recording: a missing colormap throws, as before
        @test_throws "The colormap `inferno` is not" Makie.static_to_colormap(table, :inferno)
        # tables without the default colormap have no replacement
        @test_throws "The colormap `inferno` is not" record_colormaps(() -> Makie.static_to_colormap(Makie.StaticColormaps(["magma"]), :inferno))
    end

    @testset "set_static_colormaps!(record_colormaps(f))" begin
        load() = Makie.Preferences.load_preference(Makie, "static_colormaps", nothing)
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            old_project = Base.active_project()
            try
                Base.set_active_project(joinpath(dir, "Project.toml"))
                Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    Makie.set_static_colormaps!(record_colormaps(() -> (heatmap(rand(3, 3); colormap = :magma); nothing)))
                    @test load() ⊇ ["magma"]
                    Makie.set_static_colormaps!(record_colormaps(() -> to_colormap(:Set1)))
                    @test load() ⊇ ["magma", "Set1"]
                    Makie.unset_static_colormaps!()
                end
            finally
                Base.set_active_project(old_project)
            end
        end
    end
end
