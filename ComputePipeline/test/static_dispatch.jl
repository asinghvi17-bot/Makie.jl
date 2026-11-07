using ComputePipeline.StaticDispatch: StaticDispatch, StaticDispatchError

function build_static_test_graph()
    graph = ComputeGraph()
    add_input!(graph, :a, 1.0)
    add_input!(x -> Float32(x), graph, :converted, 2)
    add_input!(graph, :index, 1)
    add_input!(graph, :flag, true)
    map!(x -> 2x, graph, :a, :b)
    map!((x, y) -> (x + y, x - y), graph, [:b, :converted], [:sum, :diff])
    # Any-typed node (StaticDispatch assumes the type seen at `install!`)
    map!(x -> x > 2 ? x : -x, graph, :a, :maybe)
    ComputePipeline.set_type!(graph.maybe, Any)
    map!(x -> x + 1, graph, :maybe, :something)
    ComputePipeline.select!(graph, :index, [:a, :b], :selected)
    ComputePipeline.select!(graph, :flag, :sum, :diff, :chosen)
    ComputePipeline.alias!(graph, :b, :b_alias)
    register_computation!(graph, [:a], [:count]) do inputs, changed, last
        return (isnothing(last) ? 1 : last.count + 1,)
    end
    child = ComputeGraph()
    add_input!(child, :parent_b, graph.b)
    map!(x -> x + 1, child, :parent_b, :child_out)
    return graph, child
end

const STATIC_TEST_OUTPUTS = (:b, :sum, :diff, :something, :selected, :chosen, :b_alias, :count)

function static_test_values(graph, child)
    return (map(k -> graph[k][], STATIC_TEST_OUTPUTS)..., child[:child_out][])
end

# Methods added by `install!` are only visible in a newer world age than the one
# the surrounding top-level testset runs in, so everything after `install!` has
# to run through `invokelatest`.
function static_test_updates!(graph, child, obs, updates)
    out = Any[]
    for (k, v) in updates
        update!(graph, k => v)
        push!(out, (static_test_values(graph, child)..., obs[]))
    end
    return out
end

function catch_error(f)
    try
        f()
        return nothing
    catch e
        return e
    end
end

@testset "install!/uninstall!" begin
    # reference run with the default dynamic hooks
    graph, child = build_static_test_graph()
    obs = ComputePipeline.get_observable!(graph, :sum)
    reference = Any[static_test_values(graph, child)]
    updates = [
        (:a, 3.0), (:converted, 5), (:index, 2), (:flag, false), (:a, 3.0), (:a, 1.0), (:converted, 7),
    ]
    append!(reference, static_test_updates!(graph, child, obs, updates))

    # same again with StaticDispatch installed after the graph is built
    graph, child = build_static_test_graph()
    obs = ComputePipeline.get_observable!(graph, :sum)
    @test static_test_values(graph, child) == reference[1]
    # resolve once more so not every edge needs `prepare!`
    graph.a = 1.0
    try
        shapes = StaticDispatch.install!(graph)
        @test StaticDispatch.isinstalled()
        @test length(shapes.graphs) == 2
        @test isempty(shapes.skipped)
        @test !isempty(shapes.selections)
        @test !isempty(shapes.abstract_refs)
        @test !isempty(shapes.observables)
        @test_throws ErrorException StaticDispatch.install!(graph)
        @test sprint(show, MIME"text/plain"(), shapes) isa String

        # every edge has a TypedEdge now
        for g in (graph, child), node in values(g.outputs)
            edge = node.parent
            edge isa ComputeEdge || continue
            StaticDispatch.is_select_edge(edge) && continue
            @test isassigned(edge.typed_edge)
        end

        # hooks resolve to the generated methods
        te = graph.b.parent.typed_edge[]
        @test which(ComputePipeline.resolve_typed_edge!, (ComputePipeline.TypedEdge,)).module === StaticDispatch
        @test which(ComputePipeline.update_input_output!, (typeof(graph.inputs[:a]),)).module === StaticDispatch

        @test @invokelatest(static_test_updates!(graph, child, obs, updates)) == reference[2:end]
        # the resolve went through the generated methods
        @test @invokelatest(StaticDispatch.isinstalled())

        # values of unknown types are rejected
        # (setting the input already resolves the observable for :sum)
        err = @invokelatest catch_error(() -> graph.a = 1) # Int instead of Float64
        @test err isa ResolveException
        @test err.error isa StaticDispatchError
        @test sprint(showerror, StaticDispatchError(:input)) isa String
    finally
        StaticDispatch.uninstall!()
    end
    @test !StaticDispatch.isinstalled()
    @test which(ComputePipeline.resolve_typed_edge!, (ComputePipeline.TypedEdge,)).module === ComputePipeline

    # dynamic behaviour is back
    graph, child = build_static_test_graph()
    @test static_test_values(graph, child) == reference[1]
    graph.a = 2 # Int, converted to the Float64 node type
    @test graph.b[] === 4.0
end

@testset "install!(...; inputs)" begin
    graph, child = build_static_test_graph()
    static_test_values(graph, child)
    graph.a = 2.0
    static_test_values(graph, child)
    try
        all_shapes = StaticDispatch.collect_shapes(graph)
        shapes = StaticDispatch.install!(graph; inputs = [graph.a])
        @test length(shapes.input_calls) == 1 < length(all_shapes.input_calls)
        # edges downstream of :a work
        @invokelatest update!(graph, :a => 3.0)
        @test @invokelatest(graph.b[]) == 6.0
        @test @invokelatest(child.child_out[]) == 7.0
        @test @invokelatest(graph.sum[]) == 8.0
        # :converted was not declared as a runtime input
        graph.converted = 3
        err = @invokelatest catch_error(() -> graph.sum[])
        @test err isa ResolveException && err.error isa StaticDispatchError
    finally
        StaticDispatch.uninstall!()
    end
end

@testset "observable_inputs" begin
    graph = ComputeGraph()
    obs = Observable(1.0)
    add_input!(graph, :from_obs, obs)
    add_input!(x -> 2x, graph, :from_obs2, Observable(1))
    add_input!(graph, :plain, 1)
    inputs = StaticDispatch.observable_inputs(graph)
    @test Set(i.name for i in inputs) == Set([:from_obs, :from_obs2])
    @test graph.observerfunctions[1].f isa ComputePipeline.ObservableInputUpdater
    obs[] = 3.0
    @test graph.from_obs[] == 3.0
end

@testset "install!(...; outputs)" begin
    graph, child = build_static_test_graph()
    static_test_values(graph, child)
    try
        shapes = StaticDispatch.install!(graph; inputs = [graph.a], outputs = [child.child_out])
        @test length(shapes.typed_edges) == 3 # b, parent_b (compute_identity), child_out
        @invokelatest update!(graph, :a => 5.0)
        @test @invokelatest(child.child_out[]) == 11.0
        err = @invokelatest catch_error(() -> graph.sum[])
        @test err isa ResolveException && err.error isa StaticDispatchError
    finally
        StaticDispatch.uninstall!()
    end
end
