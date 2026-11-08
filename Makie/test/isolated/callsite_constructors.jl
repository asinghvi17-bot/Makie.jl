using Makie.CallsiteConstructors: Callsite, generate!
using Makie: construction_types, ConstructionTypes, validated_keys

@recipe CallsiteStem (points,) begin
    color = :black
end
Makie.conversion_trait(::Type{<:CallsiteStem}) = PointBased()
function Makie.plot!(p::CallsiteStem)
    lines!(p, p.points; color = p.color)
    scatter!(p, p.points; color = p.color)
    return p
end

@testset "CallsiteConstructors" begin
    UserArgs = Tuple{Vector{Float32}, Vector{Float32}}
    @test construction_types(Plot{scatter}, UserArgs) === nothing

    sites = [
        Callsite(scatter!, Tuple{Scene, Vector{Float32}, Vector{Float32}}, @NamedTuple{color::Symbol}),
        Callsite(callsitestem!, Tuple{Scene, Vector{Point2f}}, @NamedTuple{color::RGBAf}),
    ]
    reference = scatter!(Scene(), Float32[1, 2, 3], Float32[2, 1, 3]; color = :red)
    report = generate!(sites)
    @test isempty(report.failed)
    @test isempty(report.ambiguous)
    # the plot itself and the plots of its children (with `Computed` arguments)
    @test length(report.methods) == 4

    PlotT = Scatter{Tuple{Vector{Point2f}}}
    @test construction_types(Plot{scatter}, UserArgs) === ConstructionTypes{UserArgs, Tuple{Vector{Point2f}}, PlotT}()
    @test :color in validated_keys(PlotT) && !(:colour in validated_keys(PlotT))
    # other argument types keep the generic path
    @test construction_types(Plot{scatter}, Tuple{Vector{Float64}, Vector{Float64}}) === nothing

    # inference now sees the plot type of the call site
    @test Core.Compiler.return_type(Plot{scatter}, Tuple{UserArgs, Dict{Symbol, Any}}) == PlotT
    @test Core.Compiler.return_type(Core.kwcall, Tuple{@NamedTuple{color::Symbol}, typeof(scatter!), Scene, Vector{Float32}, Vector{Float32}}) == PlotT

    # and the plot is the same as the generic one
    plt = scatter!(Scene(), Float32[1, 2, 3], Float32[2, 1, 3]; color = :red)
    @test typeof(plt) == typeof(reference)
    @test plt.converted[] == reference.converted[]
    @test plt.color[] == reference.color[]
    # keywords are still validated for call sites which were not generated for
    @test_throws Makie.InvalidAttributeError scatter!(Scene(), Float32[1, 2, 3], Float32[2, 1, 3]; colour = :red)
end

@testset "SameComputationError" begin
    using Makie.ComputePipeline
    graph = ComputePipeline.ComputeGraph()
    add_input!(graph, :a, 1.0)
    map!(x -> 2x, graph, :a, :b)
    err = try
        map!(x -> 3x, graph, :a, :b)
        nothing
    catch e
        e
    end
    @test err isa ComputePipeline.SameComputationError
    @test occursin("different callback function", sprint(showerror, err))
end
