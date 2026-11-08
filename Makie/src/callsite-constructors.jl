"""
    Makie.CallsiteConstructors

Build-time generation of the facts plot construction needs to be statically typed, for
closed-world compilers (WasmCodegen, `juliac --trim`).

Plot construction is generic: `scatter!(ax, xs, ys; color = :red)` erases its keywords into a
`Dict{Symbol, Any}`, builds a `ComputeGraph` whose nodes are partly `Any`-typed, and only then
knows which plot type it made. A compiler that can't see a concrete plot type can't compile
`plot!(plot)` or the recipe behind it. The call sites of a program, however, have concrete
argument and keyword types which a build tool can find with compiler inference (see
`WasmCodegen.CALL_OBSERVERS`). This module takes those call sites and

1. runs each natively once on sample values (the plain call, e.g. `scatter!(scene, xs, ys; color = :red)`),
   recording every `build_plot` it triggers, including those of the children of recipes,
2. generates the methods of [`Makie.construction_types`](@ref) that give `build_plot`
   the concrete types it can not infer,
3. returns the sample plots, so their `ComputeGraph`s can be passed to
   `ComputePipeline.StaticDispatch.install!`, which types the graph's update/resolve path.

Nothing changes unless [`generate!`](@ref) is called, and the generated methods only add
narrower signatures.

```julia
sites = [CallsiteConstructors.Callsite(scatter!, Tuple{Scene, Vector{Float32}, Vector{Float32}}, @NamedTuple{color::Symbol})]
report = CallsiteConstructors.generate!(sites)
# report.plots: the sample plots, report.methods: what was generated
```
"""
module CallsiteConstructors

using ..Makie
using ..Makie: Plot, Scene, SceneLike, ConstructionTypes, construction_types, plot_args, default_plot_func
using ..Makie: Point, Vec, RGBAf, Figure, GridPosition, Axis
using ..Makie.Colors: Colorant

"""
    Callsite(f, argtypes, kwtype)

A call `f(args...; kws...)` of a plot function (`scatter!`, `lines`, `plot!`, a recipe's `myplot!`),
with `argtypes::Type{<:Tuple}` the types of the positional arguments and `kwtype::Type{<:NamedTuple}`
that of the keywords.
"""
struct Callsite
    f::Any
    argtypes::Type
    kwtype::Type
end

"""
    sample_value(T::Type)
    sample_value(key::Symbol, T::Type)

A value of type `T` to construct sample plots with. Overload it for your own argument types; the
keyword version (`key` is the name of the keyword) falls back to the plain version.
"""
sample_value(key::Symbol, T::Type) = sample_value(T)
sample_value(key::Symbol, ::Type{Symbol}) = get(SYMBOL_SAMPLES, key, :red)
const SYMBOL_SAMPLES = Dict{Symbol, Symbol}(
    :marker => :circle, :colormap => :viridis, :space => :data, :markerspace => :pixel, :linestyle => :dash,
    :align => :center, :direction => :x, :cycle => :color, :interpolate => :nearest,
)
function sample_value(::Type{T}) where {T}
    isabstracttype(T) && throw(ArgumentError("No sample value for the abstract type $T: the call site has to have concrete types"))
    hasmethod(T, Tuple{}) || throw(ArgumentError("No sample value for $T: define `Makie.CallsiteConstructors.sample_value(::Type{$T})`"))
    return T()
end
sample_value(::Type{T}) where {T <: Real} = one(T)
sample_value(::Type{Symbol}) = :red
sample_value(::Type{String}) = "a"
sample_value(::Type{Nothing}) = nothing
sample_value(::Type{<:Point{N, T}}) where {N, T} = Point{N, T}(ntuple(i -> T(i), N))
sample_value(::Type{<:Vec{N, T}}) where {N, T} = Vec{N, T}(ntuple(i -> T(i), N))
sample_value(::Type{T}) where {T <: Tuple} = map(sample_value, Tuple(T.parameters))
sample_value(::Type{Vector{T}}) where {T} = T[sample_value(T) for _ in 1:3]
sample_value(::Type{Matrix{T}}) where {T} = T[sample_value(T) for _ in 1:3, _ in 1:3]
sample_value(::Type{Array{T, 3}}) where {T} = T[sample_value(T) for _ in 1:3, _ in 1:3, _ in 1:3]
sample_value(::Type{UnitRange{T}}) where {T} = T(1):T(3)
sample_value(::Type{C}) where {C <: Colorant} = convert(C, RGBAf(0.2, 0.4, 0.6, 1.0))
sample_value(::Type{Scene}) = Scene(size = (100, 100), camera = Makie.cam2d!)
sample_value(::Type{<:Axis}) = Axis(Figure()[1, 1])
sample_value(::Type{Makie.Rect2{T}}) where {T} = Makie.Rect2{T}(T(0), T(0), T(1), T(1))

# the arguments of the plot (the first one may be where it goes: a scene, axis, figure position)
function plot_arguments(args::Tuple)
    isempty(args) && return args
    a = first(args)
    return (a isa SceneLike || a isa Figure || a isa GridPosition) ? Base.tail(args) : args
end

# Records the `build_plot` calls of a sample run by temporarily replacing the fallback of
# `construction_types` (the methods generated for call sites are more specific and win).
const RECORDED = Vector{Tuple{Any, Any}}()
function recording(f)
    empty!(RECORDED)
    # (the same signature as the fallback: this replaces it, and the `finally` puts it back)
    Core.eval(Makie, :(construction_types(P::Type, A::Type) = (push!($RECORDED, (P, A)); nothing)))
    try
        return Base.invokelatest(f)
    finally
        Core.eval(Makie, :(construction_types(::Type, ::Type) = nothing))
    end
end

"""
    SamplePlot

The result of the sample run of a [`Callsite`](@ref): the plot, and `(P, UserArgs) => (Args, Converted, PlotT)`
for each `build_plot` it caused (the plot and the plots of its children).
"""
struct SamplePlot
    callsite::Callsite
    plot::Any
    builds::Vector{Pair{Tuple{Any, Any}, Any}}
end

function sample_arguments(cs::Callsite)
    names = fieldnames(cs.kwtype)
    ktypes = fieldtypes(cs.kwtype)
    args = map(sample_value, Tuple(cs.argtypes.parameters))
    kws = NamedTuple{names}(Tuple(sample_value(k, T) for (k, T) in zip(names, ktypes)))
    return args, kws
end

function flatten_plots(p)
    out = Any[]
    walk(q) = (push!(out, q); foreach(walk, q.plots))
    walk(p)
    return out
end

"""
    sample_plot(cs::Callsite; samples = (;)) -> SamplePlot

Calls `cs.f` natively on sample values and records the `build_plot` calls. `samples` maps
keyword names to the sample value to use instead of `sample_value`.
"""
function sample_plot(cs::Callsite; samples = (;))
    args, kws = sample_arguments(cs)
    kws = merge(kws, NamedTuple(k => v for (k, v) in pairs(samples) if haskey(kws, k)))
    local plot
    recording() do
        plot = cs.f(args...; kws...)
    end
    plot = plot isa Makie.FigureAxisPlot ? plot.plot : plot isa Makie.AxisPlot ? plot.plot : plot
    recorded = copy(RECORDED)
    plots = flatten_plots(plot)
    length(plots) == length(recorded) ||
        @warn "CallsiteConstructors: $(length(recorded)) plots were built for $(cs.f) but the plot has $(length(plots)) (children)" cs
    builds = Pair{Tuple{Any, Any}, Any}[]
    for (key, p) in zip(recorded, plots)
        push!(builds, key => (typeof(p.args[]), typeof(p.converted[]), typeof(p), Tuple(keys(p.kw))))
    end
    return SamplePlot(cs, plot, builds)
end

"""
    generate!(callsites; samples = (;), mod = Makie) -> (; plots, methods, ambiguous)

Runs the `callsites` natively on sample values and defines the `construction_types` methods for every
plot they build. Call sites whose samples fail are reported in `failed`. `ambiguous` are the
`(PlotType, UserArgs)` keys which different call sites made different types for: no method is
defined for them (construction stays generic there).
"""
function generate!(callsites; samples = (;), mod::Module = Makie)
    sampled = SamplePlot[]
    failed = Pair{Callsite, Any}[]
    for cs in callsites
        try
            push!(sampled, sample_plot(cs; samples))
        catch e
            push!(failed, cs => e)
        end
    end
    table = Dict{Tuple{Any, Any}, Set{Any}}()
    kwnames = Dict{Any, Set{Symbol}}()   # plot type => keyword names the samples validated
    for sp in sampled, (key, types) in sp.builds
        push!(get!(Set{Any}, table, key), types[1:3])
        union!(get!(Set{Symbol}, kwnames, types[3]), types[4])
    end
    methods = Any[]
    ambiguous = Tuple{Any, Any}[]
    for (key, variants) in table
        if length(variants) != 1
            push!(ambiguous, key)
            continue
        end
        (Args, Converted, PlotT) = only(variants)
        P, UserArgs = key
        def = :(construction_types(::Type{$P}, ::Type{$UserArgs}) = $ConstructionTypes{$Args, $Converted, $PlotT}())
        Core.eval(mod, def)
        # (the keywords were validated by the sample run, natively: `validate_attribute_keys` in `push!(scene, plot)`)
        Core.eval(mod, :(validated_keys(::Type{$PlotT}) = $(Tuple(sort!(collect(kwnames[PlotT]))))))
        push!(methods, key => (Args, Converted, PlotT))
    end
    return (; plots = [sp.plot for sp in sampled], samples = sampled, methods, ambiguous, failed)
end

end # module CallsiteConstructors
