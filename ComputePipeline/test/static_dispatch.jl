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
        @test which(ComputePipeline.resolve_edge_callback!, (ComputeEdge{ComputeGraph},)).module === StaticDispatch
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
    @test which(ComputePipeline.resolve_edge_callback!, (ComputeEdge{ComputeGraph},)).module === ComputePipeline

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

function union_slot_steps!(graph, calls)
    out = Int[]
    for a in (1.2, 1.2, 1.4, -1.0)
        graph.a = a
        graph.down[]
        push!(out, calls[])
    end
    return out, graph.down[]
end

@testset "install! with Union-typed slots" begin
    function build(calls)
        graph = ComputeGraph()
        add_input!(graph, :a, -1.0)
        # :u is typed Union{Nothing, Float64}; only `nothing` is seen before install!
        map!(a -> Ref{Union{Nothing, Float64}}(a < 0 ? nothing : round(a)), graph, :a, :u)
        map!(u -> (calls[] += 1; something(u, -1.0)), graph, :u, :down)
        graph.down[]
        graph.a = -1.2
        graph.down[]
        return graph
    end
    # reference: 1.2 -> :u = 1.0, same input again, 1.4 -> :u still 1.0, -1.0 -> nothing
    calls = Ref(0)
    graph = build(calls)
    reference = union_slot_steps!(graph, calls)
    @test reference == ([2, 2, 2, 3], -1.0)

    calls = Ref(0)
    graph = build(calls)
    try
        StaticDispatch.install!(graph)
        @test @invokelatest(union_slot_steps!(graph, calls)) == reference
    finally
        StaticDispatch.uninstall!()
    end
end

@testset "install! finds graphs sharing an Observable" begin
    obs = Observable(1.0)
    g1 = ComputeGraph()
    add_input!(g1, :x, obs)
    map!(x -> 2x, g1, :x, :y)
    g2 = ComputeGraph()
    add_input!(g2, :x, obs)
    map!(x -> x + 1, g2, :x, :z)
    # g3 is fed by an Observable of a g1 node
    g3 = ComputeGraph()
    add_input!(g3, :y, ComputePipeline.get_observable!(g1, :y))
    map!(y -> y / 2, g3, :y, :w)
    for v in (1.0, 2.0)
        obs[] = v
        g1.y[], g2.z[], g3.w[]
    end
    try
        # g1's input is fed by a plain Observable: no warning, only a debug message
        shapes = @test_logs (:debug, r"the inputs x are fed") min_level = Base.CoreLogging.Debug match_mode = :any StaticDispatch.install!(g1)
        @test length(shapes.graphs) == 3
        @invokelatest setindex!(obs, 3.0)
        @test @invokelatest(g1.y[]) == 6.0
        @test @invokelatest(g2.z[]) == 4.0
        @test @invokelatest(g3.w[]) == 3.0
    finally
        StaticDispatch.uninstall!()
    end
end

# g2 is fed by an Observable of a g1 node. Returns g2 and an updater holding g1, so
# g1 stays alive only as a field of an immutable struct
function build_producer_graphs()
    g1 = ComputeGraph()
    add_input!(g1, :x, 1.0)
    map!(x -> 2x, g1, :x, :y)
    g2 = ComputeGraph()
    add_input!(g2, :y, ComputePipeline.get_observable!(g1, :y))
    map!(y -> y + 1, g2, :y, :z)
    # Observables cached under keys which are not nodes are ignored
    g1.observables[:not_a_node] = Observable(1)
    for v in (1.0, 2.0)
        g1.x = v
        g2.z[]
    end
    return g2, ComputePipeline.GraphObservablesUpdater(g1)
end

@testset "install! finds the graph producing an Observable" begin
    StaticDispatch.track_graphs!()
    @test StaticDispatch.istracking()
    g2, updater = build_producer_graphs()
    for _ in 1:3
        GC.gc(true)
    end
    g1 = updater.graph
    try
        shapes = @test_logs StaticDispatch.install!(g2) # no warning
        @test length(shapes.graphs) == 2
        @test any(g -> g === g1, shapes.graphs)
        # install! stops tracking
        @test !StaticDispatch.istracking()
        @test isempty(ComputePipeline.TRACKED_GRAPHS)
        @invokelatest setproperty!(g1, :x, 3.0)
        @test @invokelatest(g1.y[]) == 6.0
        @test @invokelatest(g2.z[]) == 7.0
    finally
        StaticDispatch.uninstall!()
    end
end

@testset "install! without tracking" begin
    @test !StaticDispatch.istracking()
    # the producer can't be found from g2, install! warns
    g2, updater = build_producer_graphs()
    try
        # can't be told apart from a plain Observable: no warning, only a debug message
        shapes = @test_logs (:debug, r"the inputs y are fed by Observables which no collected") min_level = Base.CoreLogging.Debug match_mode = :any StaticDispatch.install!(g2)
        @test length(shapes.graphs) == 1
    finally
        StaticDispatch.uninstall!()
    end
    # explicit roots
    g1 = updater.graph
    try
        shapes = @test_logs StaticDispatch.install!(g2, g1)
        @test length(shapes.graphs) == 2
        @invokelatest setproperty!(g1, :x, 3.0)
        @test @invokelatest(g2.z[]) == 7.0
    finally
        StaticDispatch.uninstall!()
    end
end

@testset "graph tracking" begin
    # off: nothing is recorded
    @test !StaticDispatch.istracking()
    foreach(_ -> ComputeGraph(), 1:100)
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
    StaticDispatch.track_graphs!()
    graph = ComputeGraph()
    @test length(ComputePipeline.TRACKED_GRAPHS) == 1
    @test ComputePipeline.TRACKED_GRAPHS[1] === graph
    StaticDispatch.untrack!()
    @test !StaticDispatch.istracking()
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
    ComputeGraph()
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
end

@testset "track_graphs! do-block" begin
    graphs = StaticDispatch.track_graphs!() do
        @test StaticDispatch.istracking()
        return [ComputeGraph(), ComputeGraph()]
    end
    @test length(graphs) == 2
    @test !StaticDispatch.istracking()
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
    # stops tracking if building fails
    @test_throws ErrorException StaticDispatch.track_graphs!() do
        ComputeGraph()
        error("build failed")
    end
    @test !StaticDispatch.istracking()
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
end

@testset "track_graphs! can't be nested" begin
    StaticDispatch.track_graphs!() do
        outer = ComputeGraph()
        inner_ran = Ref(false)
        @test_throws ErrorException StaticDispatch.track_graphs!(() -> (inner_ran[] = true))
        @test_throws ErrorException StaticDispatch.track_graphs!()
        @test !inner_ran[]
        # the outer session is intact
        @test StaticDispatch.istracking()
        @test length(ComputePipeline.TRACKED_GRAPHS) == 1
        @test ComputePipeline.TRACKED_GRAPHS[1] === outer
        ComputeGraph()
        @test length(ComputePipeline.TRACKED_GRAPHS) == 2
    end
    @test !StaticDispatch.istracking()
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
end

@testset "tracking stopped while a graph is constructed" begin
    # A constructor which read `TRACK_GRAPHS[] == true` and continues after
    # `untrack!()` re-checks the flag under the lock and does not add its graph.
    StaticDispatch.track_graphs!()
    graph = ComputeGraph()
    @test length(ComputePipeline.TRACKED_GRAPHS) == 1
    StaticDispatch.untrack!()
    ComputePipeline.track_graph!(graph) # the rest of that constructor
    @test isempty(ComputePipeline.TRACKED_GRAPHS)
    # concurrent constructions while tracking stops leave nothing behind
    for _ in 1:20
        StaticDispatch.track_graphs!()
        tasks = [Threads.@spawn(foreach(_ -> ComputeGraph(), 1:200)) for _ in 1:4]
        StaticDispatch.untrack!()
        foreach(wait, tasks)
        @test isempty(ComputePipeline.TRACKED_GRAPHS)
    end
end

@testset "install! with a producer built before tracking" begin
    function producer()
        g1 = ComputeGraph()
        add_input!(g1, :x, 1.0)
        map!(x -> 2x, g1, :x, :y)
        return g1
    end
    function consumer(obs)
        g2 = ComputeGraph()
        add_input!(g2, :y, obs)
        map!(y -> y + 1, g2, :y, :z)
        g2.z[]
        return g2
    end
    # its Observable is created while tracking: found
    g1 = producer()
    try
        StaticDispatch.track_graphs!() do
            g2 = consumer(ComputePipeline.get_observable!(g1, :y))
            shapes = @test_logs StaticDispatch.install!(g2) # no warning
            @test length(shapes.graphs) == 2
            @test isempty(ComputePipeline.TRACKED_OBSERVABLES)
        end
        @invokelatest setproperty!(g1, :x, 3.0)
        @test @invokelatest(g1.y[]) == 6.0
    finally
        StaticDispatch.uninstall!()
    end
    # its Observable is created before tracking: not found, only a debug message
    g1 = producer()
    obs = ComputePipeline.get_observable!(g1, :y)
    try
        StaticDispatch.track_graphs!() do
            g2 = consumer(obs)
            shapes = @test_logs (:debug, r"the inputs y are fed") min_level = Base.CoreLogging.Debug match_mode = :any StaticDispatch.install!(g2)
            @test length(shapes.graphs) == 1
        end
    finally
        StaticDispatch.uninstall!()
    end
    # ... unless `get_observable!` returns it again while tracking
    g1 = producer()
    obs = ComputePipeline.get_observable!(g1, :y)
    try
        StaticDispatch.track_graphs!() do
            g2 = consumer(obs)
            @test ComputePipeline.get_observable!(g1, :y) === obs
            shapes = @test_logs StaticDispatch.install!(g2) # no warning
            @test length(shapes.graphs) == 2
            @test any(g -> g === g1, shapes.graphs)
        end
        @invokelatest setproperty!(g1, :x, 3.0)
        @test @invokelatest(g1.y[]) == 6.0
    finally
        StaticDispatch.uninstall!()
    end
    # ... or it is passed as a root
    g1 = producer()
    obs = ComputePipeline.get_observable!(g1, :y)
    g2 = consumer(obs)
    try
        shapes = StaticDispatch.install!(g2, g1)
        @test length(shapes.graphs) == 2
        @invokelatest setproperty!(g1, :x, 3.0)
        @test @invokelatest(g1.y[]) == 6.0
    finally
        StaticDispatch.uninstall!()
    end
    # with tracking off, a cached `get_observable!` records nothing
    @test ComputePipeline.get_observable!(g1, :y) === obs
    @test isempty(ComputePipeline.TRACKED_OBSERVABLES)
    @test !StaticDispatch.istracking()
end

@testset "Union slots are split into concrete branches" begin
    U = Union{Nothing, Float64}
    @test Set(StaticDispatch.split_unions((U, nothing, Int))) ==
        Set([(Nothing, nothing, Int), (Float64, nothing, Int)])
    @test length(StaticDispatch.split_unions((U, U))) == 4
    @test StaticDispatch.split_unions((nothing,)) == [(nothing,)]
    @test StaticDispatch.split_unions(()) == [()]
    # more than MAX_UNION_SPLITS combinations keep the Unions
    U4 = Union{Nothing, Float64, Int, Bool}
    @test StaticDispatch.split_unions((U4, U4, U4)) == [(U4, U4, U4)]
    # the generated method builds concretely typed NamedTuples per member
    graph = ComputeGraph()
    add_input!(graph, :a, -1.0)
    map!(a -> Ref{U}(a < 0 ? nothing : a), graph, :a, :u)
    map!(u -> something(u, 0.0), graph, :u, :down)
    graph.down[]
    graph.a = 1.0
    graph.down[]
    code = string(StaticDispatch.generate(graph))
    @test occursin("::Nothing,)", code) && occursin("::Float64,)", code)
    @test !occursin("::Union{Nothing, Float64},)", code)
end

@testset "is_same pairs warning" begin
    types = [Vector{T} for T in (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float64)]
    @test_logs (:warn, r"72 pairs of different value types") StaticDispatch.is_same_chain(:a, :b, types, "test")
    @test_logs StaticDispatch.is_same_chain(:a, :b, types[1:3], "test")
end

function cross_type_steps!(graph, calls)
    out = Int[]
    # :u is [1] (Int) at first. Equal, different type; different; equal, different type; same input
    for a in (1.0, 2.0, -2.0, -2.0)
        graph.a = a
        graph.down[]
        push!(out, calls[])
    end
    return out
end

@testset "install! keeps is_same for values of different types" begin
    function build(calls)
        graph = ComputeGraph()
        add_input!(graph, :a, -1.0)
        # equal values of different types are the same for `is_same`: [|a|], Int for a < 0
        map!(graph, :a, :u) do a
            return Ref{Union{Vector{Int}, Vector{Float64}}}(a < 0 ? [round(Int, -a)] : [round(a)])
        end
        map!(u -> (calls[] += 1; sum(u)), graph, :u, :down)
        # inputs with values of different types
        add_input!(graph, :v, [1, 2])
        add_input!(graph, :w, [1.0])
        map!(v -> (calls[] += 1; length(v)), graph, :v, :vlen)
        graph.down[], graph.vlen[], graph.w[]
        graph.a = -1.2
        graph.down[]
        return graph
    end
    function input_steps!(graph, calls)
        out = Int[]
        for v in ([1.0, 2.0], [1, 2], [1, 2, 3])
            graph.v = v
            graph.vlen[]
            push!(out, calls[])
        end
        return out
    end
    calls = Ref(0)
    graph = build(calls)
    reference = (cross_type_steps!(graph, calls), input_steps!(graph, calls))
    @test reference == ([2, 3, 3, 3], [3, 3, 4])

    calls = Ref(0)
    graph = build(calls)
    try
        StaticDispatch.install!(graph)
        @test @invokelatest(cross_type_steps!(graph, calls)) == reference[1]
        @test @invokelatest(input_steps!(graph, calls)) == reference[2]
    finally
        StaticDispatch.uninstall!()
    end
end

@testset "install! does not hold INSTALL_LOCK while running graph code" begin
    graph = ComputeGraph()
    add_input!(graph, :a, 1.0)
    seen = Ref{Any}(nothing)
    map!(graph, :a, :b) do a
        # a callback running under the graph lock during `install!`
        seen[] = (islocked(StaticDispatch.INSTALL_LOCK), StaticDispatch.isinstalled())
        return 2a
    end
    try
        StaticDispatch.install!(graph) # resolves :b in `prepare!`
        @test seen[] == (false, false)
    finally
        StaticDispatch.uninstall!()
    end
    # `isinstalled` does not wait for INSTALL_LOCK
    lock(StaticDispatch.INSTALL_LOCK)
    t = try
        t = @async StaticDispatch.isinstalled()
        @test timedwait(() -> istaskdone(t), 10) === :ok
        t
    finally
        unlock(StaticDispatch.INSTALL_LOCK)
    end
    @test fetch(t) === false
end

struct StaticDispatchTestEdge <: ComputePipeline.AbstractEdge end

@testset "install! records methods if evaluation fails" begin
    defs = [
        :(ComputePipeline.other_edge(f, edge::$StaticDispatchTestEdge) = :added),
        :(error("evaluation failed")),
    ]
    @test_throws ErrorException StaticDispatch.eval_tracked!(StaticDispatch, defs)
    try
        @test StaticDispatch.isinstalled()
        @test @invokelatest(ComputePipeline.other_edge(identity, StaticDispatchTestEdge())) === :added
    finally
        StaticDispatch.uninstall!()
    end
    @test !StaticDispatch.isinstalled()
    @test @invokelatest(ComputePipeline.other_edge(identity, StaticDispatchTestEdge())) isa StaticDispatchTestEdge
end

@testset "install! keeps ResolveException{SelectException}" begin
    graph = ComputeGraph()
    add_input!(graph, :idx, 1)
    add_input!(graph, :a, 1.0)
    add_input!(graph, :b, 2.0)
    ComputePipeline.select!(graph, :idx, [:a, :b], :out)
    graph.out[]
    graph.idx = 5
    native = catch_error(() -> graph.out[])
    graph.idx = 2
    graph.out[]
    try
        StaticDispatch.install!(graph)
        graph.idx = 5
        err = @invokelatest catch_error(() -> graph.out[])
        @test native isa ResolveException{ComputePipeline.SelectException}
        @test err isa ResolveException{ComputePipeline.SelectException}
        @test @invokelatest(sprint(showerror, err)) == sprint(showerror, native)
    finally
        StaticDispatch.uninstall!()
    end
    # the generic showerror handles a widened type parameter the same way
    wide = ResolveException{Exception}(native.start, native.error)
    @test sprint(showerror, wide) == sprint(showerror, native)
end

@testset "install! passes on an existing ResolveException" begin
    # a callback which reads a failing node of another graph: the nested resolve
    # throws a `ResolveException` which the outer resolve must not wrap again
    function nested_graphs()
        inner = ComputeGraph()
        add_input!(inner, :a, 1.0)
        map!(inner, :a, :z) do a
            a > 2 && error("inner failed")
            return a
        end
        outer = ComputeGraph()
        add_input!(outer, :b, 1.0)
        map!(outer, :b, :out) do b
            return b + inner.z[]
        end
        outer.out[]
        outer.b = 2.0
        outer.out[]
        return inner, outer
    end
    function nested_error(inner, outer)
        inner.a = 3.0
        outer.b = 3.0
        return catch_error(() -> outer.out[])
    end

    inner, outer = nested_graphs()
    native = nested_error(inner, outer)
    @test native isa ResolveException{ErrorException}
    @test native.start === inner.z

    inner, outer = nested_graphs()
    try
        StaticDispatch.install!(outer, inner)
        err = @invokelatest nested_error(inner, outer)
        @test err isa ResolveException
        @test !(err.error isa ResolveException)
        @test err.error isa ErrorException
        @test err.start === inner.z
        @test @invokelatest(sprint(showerror, err)) == sprint(showerror, native)
        existing = ResolveException(outer.out, ErrorException("x"))
        @test @invokelatest(ComputePipeline.resolve_exception(inner.z, existing)) === existing
    finally
        StaticDispatch.uninstall!()
    end
end

# The calls in the optimized IR of `f(args...)` (in the current world) which are
# not statically resolved to one method (`:call`), as `(function name, argument
# types)`, and the signatures of statically resolved ones (`:invoke`), as `(function
# name, specialization types)`
function compiled_calls(f, sig::Type{<:Tuple})
    ci = only(Base.code_typed(f, sig; optimize = true, world = Base.get_world_counter()))[1]
    argtype(a) = a isa Core.SSAValue ? ci.ssavaluetypes[a.id] :
        a isa Core.Argument ? ci.slottypes[a.n] : Core.Typeof(a)
    dynamic = Tuple{Symbol, Vector{Any}}[]
    static = Tuple{Symbol, Any}[]
    for stmt in ci.code
        stmt isa Expr || continue
        if stmt.head === :call && stmt.args[1] isa GlobalRef
            push!(dynamic, (stmt.args[1].name, Any[argtype(a) for a in stmt.args[2:end]]))
        elseif stmt.head === :invoke
            target = stmt.args[1]
            mi = target isa Core.CodeInstance ? target.def : target
            mi isa Core.MethodInstance && push!(static, (mi.def.name, mi.specTypes))
        end
    end
    return dynamic, static
end

@testset "install! with an Any-typed Observable" begin
    # the in-place update keeps the node dirty while the value stays equal, so
    # whether the Observable notifies depends on `is_same(obs[], value)`
    function any_observable_graph(held = nothing)
        g = ComputeGraph()
        add_input!(g, :x, 1.0)
        register_computation!(g, [:x], [:y]) do inputs, changed, cached
            v = isnothing(cached) ? [0.0] : cached.y
            v[1] = floor(inputs.x)
            return (v,)
        end
        ComputePipeline.set_type!(g.y, Any)
        obs = ComputePipeline.get_observable!(g, :y)
        isnothing(held) || (obs.val = held) # a value of another type than the node's
        notified = Ref(0)
        on(_ -> notified[] += 1, obs)
        g.x = 1.5 # resolve once more, so the TypedEdge exists
        return g, obs, notified
    end
    function any_observable_updates!(g, obs, notified)
        out = Any[]
        for x in (1.2, 2.5, 2.7, 3.1, 3.9)
            update!(g, :x => x)
            push!(out, (copy(obs[]), notified[]))
        end
        return out
    end

    g, obs, notified = any_observable_graph()
    @test obs isa Observable{Any}
    reference = any_observable_updates!(g, obs, notified)
    @test last.(reference) == [0, 1, 1, 2, 2] # equal values do not notify

    g, obs, notified = any_observable_graph()
    try
        shapes = StaticDispatch.install!(g)
        @test (typeof(obs), typeof(g.y.value)) in shapes.observables
        @test @invokelatest(any_observable_updates!(g, obs, notified)) == reference
        # no runtime dispatch on the abstract values in the installed methods
        sig = Tuple{Observable{Any}, ComputePipeline.Computed, Bool}
        dynamic, static = @invokelatest compiled_calls(ComputePipeline.sync_observable!, sig)
        @test isdisjoint(first.(dynamic), [:sync_observable_value!, :is_same, :is_same_observable, :deepcopy])
        watched = [:sync_observable_value!, :deepcopy, :is_same, :is_same_observable]
        calls = [T for (name, T) in static if name in watched]
        @test all(T -> all(isconcretetype, T.parameters[2:end]), calls) # not called with an abstract value
        sig = Tuple{Observable{Any}, Any}
        dynamic, _ = @invokelatest compiled_calls(ComputePipeline.is_same_observable, sig)
        @test isdisjoint(first.(dynamic), [:is_same])
        # value types not seen by `install!`
        err = catch_error() do
            @invokelatest ComputePipeline.sync_observable!(obs, g.y, true)
            g.y.value[] = 1 # an Int instead of the Vector{Float64} seen
            @invokelatest ComputePipeline.sync_observable!(obs, g.y, true)
        end
        @test err isa StaticDispatchError && err.kind === :observable
    finally
        StaticDispatch.uninstall!()
    end

    @testset "install! with an Any-typed Observable holding another value type" begin
        # `[1]` and `[1.0]` are the same for `is_same`, but the Observable holds a
        # `Vector{Int}` while the node only ever has `Vector{Float64}`s
        g, obs, notified = any_observable_graph([1])
        @test obs[] isa Vector{Int}
        reference = any_observable_updates!(g, obs, notified)
        @test last.(reference) == [0, 1, 1, 2, 2] # equal values do not notify

        g, obs, notified = any_observable_graph([1])
        try
            shapes = StaticDispatch.install!(g)
            @test Vector{Int} in shapes.observable_held_types[typeof(obs)]
            @test obs[] isa Vector{Int}
            @test @invokelatest(any_observable_updates!(g, obs, notified)) == reference
            sig = Tuple{Observable{Any}, Any}
            dynamic, static = @invokelatest compiled_calls(ComputePipeline.is_same_observable, sig)
            @test isdisjoint(first.(dynamic), [:is_same, :isequal])
            # (inlined) comparison of the held `Vector{Int}` with the node's `Vector{Float64}`
            @test any(c -> c == (:isa, Any[Any, Type{Vector{Int}}]), dynamic)
            # a value type not seen at `install!` and not produced by the node is "not the same",
            # like for the other `is_same` chains
            obs.val = 1
            @test !@invokelatest(ComputePipeline.is_same_observable(obs, [1.0]))
        finally
            StaticDispatch.uninstall!()
        end
    end
end

@testset "StaticDispatchError messages" begin
    graph = ComputeGraph()
    add_input!(graph, :a, 1.0)
    map!(x -> 2x, graph, :a, :b)
    graph.b[]
    graph.a = 2.0
    graph.b[]
    try
        StaticDispatch.install!(graph)
        graph.a = 1 # Int instead of Float64
        err = @invokelatest catch_error(() -> graph.b[])
        @test err isa ResolveException{StaticDispatchError}
        @test err.error.kind === :input
        @test err.error.name === :a
        @test err.error.got[2] === Int
        @test err.error.expected == (Float64,)
        msg = sprint(showerror, err.error)
        @test occursin("at: a", msg)
        @test occursin("got: ", msg) && occursin("Int64", msg)
        @test occursin("types seen by `install!`: (Float64,)", msg)
    finally
        StaticDispatch.uninstall!()
    end
end
