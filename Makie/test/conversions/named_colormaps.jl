using Makie: Reverse, StaticColormaps, all_gradient_names, colorbrewer_8color_names

include("named_colormaps_reference.jl")

brewer_names = sort!(collect(intersect(keys(Makie.ColorBrewer.colorSchemes), all_gradient_names)))

@testset "named colormaps" begin
    @testset "registry lookups (the default)" begin
        # unless Makie was precompiled with the `static_colormaps` preference
        if !Makie.static_colormaps_enabled
            for name in all_gradient_names
                @test to_colormap(name) == registry_colormap(name)
                @test to_colormap(Symbol(name)) == registry_colormap(name)
            end
            @test to_colormap(:Accent) == to_colormap(Makie.ColorBrewer.palette("Accent", 8))
            @test length(to_colormap(:Accent)) == 8
            @test to_colormap(:Spectral) == to_colormap(:Spectral_11) # alias

            # the tables of the static lookup are empty, they only exist when the preference is set
            @test Makie.static_colormap_names === nothing
            @test isempty(Makie.static_colormaps.colormaps)
            @test isempty(Makie.static_colormaps.colorbrewer_palettes)

            # Every lookup goes to the registry, so a scheme registered under an existing name replaces the old one
            colorschemes = Makie.PlotUtils.ColorSchemes.colorschemes
            red_blue = [RGBAf(1, 0, 0, 1), RGBAf(0, 0, 1, 1)]
            for (key, aliases) in (:magma => (:magma,), :Set1_9 => (:Set1_9, :Set1)) # a scheme, and a scheme with an alias
                original = colorschemes[key]
                try
                    colorschemes[key] = Makie.ColorSchemes.ColorScheme([RGB(1, 0, 0), RGB(0, 0, 1)])
                    for name in aliases
                        @test to_colormap(name) == red_blue
                        @test to_colormap(string(name)) == red_blue
                        @test to_colormap(Reverse(name)) == reverse(red_blue)
                        @test to_colormap((name, 0.5)) == RGBAf.(color.(red_blue), 0.5)
                    end
                    # categorical colors of schemes other than ColorBrewer's are taken from the registry, too
                    @test categorical_colors(key, 2) == red_blue
                    @test categorical_colors(key, 2, true) == red_blue
                    @test categorical_colors(string(key), 1) == red_blue[1:1]
                    @test categorical_colors(key, 5, true) == [red_blue; red_blue; red_blue[1:1]]
                finally
                    colorschemes[key] = original
                end
                @test to_colormap(key) == registry_colormap(string(key))
            end
            # ColorBrewer's categorical palettes come from ColorBrewer, they are not affected
            @test categorical_colors(:Set1, 3) == brewer_palette("Set1", 3)
        end
    end

    full = StaticColormaps(all_gradient_names)

    @testset "tables of all colormaps agree with the registries" begin
        registry_names = Set{String}(
            String.(
                union(
                    keys(Makie.PlotUtils.ColorSchemes.colorschemes),
                    keys(Makie.PlotUtils.COLORSCHEME_ALIASES),
                    keys(Makie.PlotUtils.MISC_COLORSCHEMES)
                )
            )
        )
        union!(registry_names, colorbrewer_8color_names)
        @test Set(keys(full.colormaps)) == registry_names
        @test length(registry_names) == length(all_gradient_names)
        @test Set(keys(full.colorbrewer_palettes)) == Set(brewer_names)
        @test issubset(Set(keys(full.colorbrewer_palettes)), Set(keys(Makie.ColorBrewer.colorSchemes)))
        @test !isempty(brewer_names)
        for name in all_gradient_names
            @test full.colormaps[name] == registry_colormap(name)
        end
        # the colors in the palette tables are those of ColorBrewer
        for name in brewer_names
            for (n, colors) in enumerate(full.colorbrewer_palettes[name])
                if haskey(Makie.ColorBrewer.colorSchemes[name], string(n))
                    @test colors == to_colormap(Makie.ColorBrewer.palette(name, n))
                else
                    @test isempty(colors)
                end
            end
        end
    end

    @testset "static lookup matches the lookup in the registry" begin
        for name in all_gradient_names
            expected = registry_colormap(name)
            @test Makie.static_to_colormap(full, name) == expected
            @test Makie.static_to_colormap(full, Symbol(name)) == expected
            # composites, built from the typed lookup the way `to_colormap` builds them from its lookup
            @test reverse(Makie.static_to_colormap(full, name)) == to_colormap(Reverse(name))
            alpha_scaled = Makie.static_to_colormap(full, name)
            @test RGBAf.(color.(alpha_scaled), alpha.(alpha_scaled) .* 0.3) == to_colormap((name, 0.3))
        end
        # names that end in _r
        # (the registry has none at the moment, so also check that lookups of names it doesn't have fail the same way)
        reversed_names = filter(endswith("_r"), collect(all_gradient_names))
        Makie.static_colormaps_enabled || @test_throws "There is no color gradient named viridis_r" to_colormap(:viridis_r)
        @test occursin("`viridis_r` is not in Makie's static colormap tables", outcome(() -> Makie.static_to_colormap(full, :viridis_r))[2])
        for name in reversed_names
            @test Makie.static_to_colormap(full, name) == to_colormap(name)
            base = name[1:(end - 2)]
            if base in all_gradient_names && !(name in colorbrewer_8color_names)
                @test Makie.static_to_colormap(full, name) == reverse(Makie.static_to_colormap(full, base))
            end
        end

        for name in brewer_names
            sizes = 0:(length(full.colorbrewer_palettes[name]) + 2) # beyond the defined sizes, too
            for n in sizes
                @test outcome(() -> Makie.static_categorical_colors(full, name, n, false)) ==
                    outcome(() -> categorical_colors(name, n))
                @test outcome(() -> Makie.static_categorical_colors(full, Symbol(name), n, true)) ==
                    outcome(() -> categorical_colors(Symbol(name), n, true))
            end
        end
        for name in ("viridis", "Accent", "tab10", "RdBu_5")
            for n in (1, 3, 9), cycle in (false, true)
                @test outcome(() -> Makie.static_categorical_colors(full, name, n, cycle)) ==
                    outcome(() -> categorical_colors(name, n, cycle))
            end
        end
        @test length(Makie.static_categorical_colors(full, :viridis, 300, true)) == 300
        @test_throws ArgumentError Makie.static_categorical_colors(full, :Set1, 2, false)
        @test_throws "Scheme Blues is undefined for 12 colors." Makie.static_categorical_colors(full, :Blues, 12, false)
        @test_throws "Not enough colors" Makie.static_categorical_colors(full, :viridis, 300, false)
    end

    @testset "results are copies" begin
        table = StaticColormaps(["viridis", "Set1"])
        cmap = Makie.static_to_colormap(table, :viridis)
        cmap[1] = RGBAf(1, 0, 0, 1)
        @test Makie.static_to_colormap(table, :viridis)[1] != RGBAf(1, 0, 0, 1)
        @test Makie.static_to_colormap(table, :viridis) !== Makie.static_to_colormap(table, :viridis)
        cols = Makie.static_categorical_colors(table, :Set1, 5, false)
        cols[1] = RGBAf(0, 0, 0, 1)
        @test Makie.static_categorical_colors(table, :Set1, 5, false)[1] != RGBAf(0, 0, 0, 1)
    end

    @testset "tables of some colormaps" begin
        table = StaticColormaps(["magma", "Set1"])
        @test Set(keys(table.colormaps)) == Set(["magma", "Set1"])
        @test Set(keys(table.colorbrewer_palettes)) == Set(["Set1"])
        @test Makie.static_to_colormap(table, :magma) == to_colormap(:magma)
        @test Makie.static_categorical_colors(table, "Set1", 5, false) == categorical_colors(:Set1, 5)
        @test Makie.static_categorical_colors(table, :magma, 4, false) == categorical_colors(:magma, 4)

        # a colormap that isn't in the table, or doesn't exist, errors with its name and how to add it
        for f in (
                () -> Makie.static_to_colormap(table, :inferno),
                () -> Makie.static_to_colormap(table, "inferno"),
                () -> Makie.static_categorical_colors(table, :inferno, 3, false),
                () -> Makie.static_categorical_colors(table, :Set2, 3, false), # a ColorBrewer scheme, but not in the table
            )
            err = try
                f()
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("The colormap `", err.msg)
            @test occursin("not in Makie's static colormap tables", err.msg)
            @test occursin("which hold 2 colormaps", err.msg)
            @test occursin("Makie.set_static_colormaps!(\"", err.msg)
            @test occursin("static_colormaps", err.msg)
        end
        @test_throws "The colormap `inferno` is not in Makie's static colormap tables" Makie.static_to_colormap(table, :inferno)
        @test_throws "Makie.set_static_colormaps!(\"inferno\")" Makie.static_to_colormap(table, "inferno")
        @test_throws "The colormap `Set2` is not" Makie.static_categorical_colors(table, "Set2", 3, false)
    end

    @testset "type stability" begin
        for name in (:viridis, "viridis")
            @test @inferred(Makie.static_to_colormap(full, name)) isa Vector{RGBAf}
        end
        @test Base.return_types(Makie.static_to_colormap, (StaticColormaps, Union{String, Symbol})) == [Vector{RGBAf}]
        @test Base.return_types(Makie.static_categorical_colors, (StaticColormaps, Union{String, Symbol}, Int, Bool)) == [Vector{RGBAf}]
        @test fieldtype(StaticColormaps, :colormaps) === Dict{String, Vector{RGBAf}}
        @test fieldtype(StaticColormaps, :colorbrewer_palettes) === Dict{String, Vector{Vector{RGBAf}}}
        @test Base.return_types(to_colormap, (Reverse{Symbol},)) == [Vector{RGBAf}]
        @test Base.return_types(to_colormap, (Tuple{Symbol, Float64},)) == [Vector{RGBAf}]
    end

    @testset "the static_colormaps preference" begin
        names_from = Makie.static_colormap_names_from
        @test names_from(nothing) === nothing
        @test names_from(false) === nothing
        @test names_from(true) == sort!(collect(all_gradient_names))
        @test names_from("all") == sort!(collect(all_gradient_names))
        # the default colormap is always included, names are sorted and unique
        @test names_from(String[]) == Makie.static_default_colormaps
        @test names_from(["magma"]) == ["magma", "viridis"]
        @test names_from(["viridis", "Set1", "magma", "magma"]) == ["Set1", "magma", "viridis"]
        @test names_from("magma") == ["magma", "viridis"]
        @test names_from([:magma]) == ["magma", "viridis"]
        @test_throws "Unknown colormap name(s) in the `static_colormaps` preference: not_a_gradient" names_from(["magma", "not_a_gradient"])
        # the theme's default colormap is always available
        theme_colormaps = Set{String}()
        function collect_colormaps(attributes)
            for (_, value) in attributes
                value = value isa Makie.Observable ? value[] : value
                if value isa Makie.Attributes
                    collect_colormaps(value)
                elseif value isa Union{Symbol, AbstractString} && string(value) in all_gradient_names
                    push!(theme_colormaps, string(value))
                end
            end
            return
        end
        collect_colormaps(Makie.MAKIE_DEFAULT_THEME)
        @test "viridis" in theme_colormaps
        @test theme_colormaps ⊆ Set(Makie.static_default_colormaps)
        @test Makie.static_default_colormaps ⊆ all_gradient_names

        # set_static_colormaps! writes the preference (here into a temporary project, so nothing outside is touched)
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            old_project = Base.active_project()
            try
                Base.set_active_project(joinpath(dir, "Project.toml"))
                Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    Makie.set_static_colormaps!(:magma, "Set1")
                    @test Makie.Preferences.load_preference(Makie, "static_colormaps") == ["magma", "Set1"]
                    Makie.set_static_colormaps!([:plasma, "Set2"])
                    @test Makie.Preferences.load_preference(Makie, "static_colormaps") == ["plasma", "Set2"]
                    Makie.set_static_colormaps!(all = true)
                    @test Makie.Preferences.load_preference(Makie, "static_colormaps") == "all"
                    @test_throws "Unknown colormap name(s): not_a_gradient" Makie.set_static_colormaps!("not_a_gradient")
                    Makie.unset_static_colormaps!()
                    @test Makie.Preferences.load_preference(Makie, "static_colormaps", nothing) === nothing
                end
            finally
                Base.set_active_project(old_project)
            end
        end
    end
end

# All of the above can test the static lookup in a process whose `to_colormap` uses the registry. Whether
# `to_colormap`, `Reverse` and `(name, alpha)` tuples, `categorical_colors` and `Palette` take their colors from the
# static tables when the preference is set is checked in a Julia process that precompiles Makie with it. That takes a
# few minutes, so it is only run if requested (`MAKIE_TEST_STATIC_COLORMAPS=true`).
if get(ENV, "MAKIE_TEST_STATIC_COLORMAPS", "false") == "true"
    @testset "to_colormap with the static_colormaps preference" begin
        makie_dir = pkgdir(Makie)
        mktempdir() do dir
            project = joinpath(dir, "env")
            mkpath(project)
            write(
                joinpath(project, "LocalPreferences.toml"), """
                [Makie]
                static_colormaps = ["magma", "Set1", "Accent", "Spectral"]
                precompile_workload = false
                """
            )
            julia = Base.julia_cmd()
            setup = """
            using Pkg
            Pkg.develop([PackageSpec(path = $(repr(joinpath(dirname(makie_dir), "ComputePipeline"))))])
            Pkg.develop([PackageSpec(path = $(repr(makie_dir)))])
            Pkg.add("Test")
            """
            @test success(pipeline(`$julia --project=$project -e $setup`; stdout = stdout, stderr = stderr))
            script = joinpath(@__DIR__, "static_colormaps_child.jl")
            @test success(pipeline(`$julia --project=$project $script`; stdout = stdout, stderr = stderr))
        end
    end
end
