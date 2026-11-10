"""
    ComputePipeline.StaticDispatch

Opt-in, build-time devirtualization of the `ComputeGraph` update/resolve path for
closed-world compilation (e.g. `juliac --trim` or WasmCodegen).

In a normal session `ComputeGraph`s call edge callbacks, input conversion
functions and `is_same` on runtime types. Once the graphs of an application are
built, [`install!`](@ref) collects the types they use and adds methods to the
hook functions of ComputePipeline (see "Hooks for ahead-of-time compilation" in
ComputePipeline.jl) which select the right code through `isa` checks. Since these
methods are added on narrower signatures than the defaults, no method is
overwritten and the hook calls become static. Nothing changes unless
`install!` is called; [`uninstall!`](@ref) removes the added methods again.

After `install!`, the graphs are assumed to be frozen: values of new types,
newly added edges or edges which were never resolved throw a
[`StaticDispatchError`](@ref) instead of being handled dynamically.

```julia
using ComputePipeline.StaticDispatch: StaticDispatch
StaticDispatch.track_graphs!() # record the graphs built from here on
graph = ComputeGraph()
add_input!(graph, :a, 1.0)
map!(x -> 2x, graph, :a, :b)
StaticDispatch.install!(graph) # also stops tracking
# compile entry points which use `graph`
```
"""
module StaticDispatch

using ..ComputePipeline: ComputePipeline, ComputeGraph, ComputeEdge, Input, Computed,
    TypedEdge, AbstractEdge, SelectException, hasparent, select, compute_identity
using Base: RefValue
using Observables: Observables, Observable

"""
    StaticDispatchError(kind::Symbol, name::Symbol, got, expected)

Thrown by the methods added by [`install!`](@ref) when the graph reaches a state
that did not exist when `install!` was called, e.g. an input set to a value of
a new type or an edge that was never resolved. `name` is the input or node
involved, `got` the type or types (a `Vector{Any}`) found and `expected` the types
`install!` saw at that place (`nothing` if not applicable). The message is only formatted when shown.
"""
struct StaticDispatchError <: Exception
    kind::Symbol
    name::Symbol
    got::Any
    expected::Any
end
StaticDispatchError(kind::Symbol) = StaticDispatchError(kind, Symbol(""), nothing, nothing)

function Base.showerror(io::IO, e::StaticDispatchError)
    print(io, "StaticDispatchError: ")
    msg = if e.kind === :untyped_edge
        "edge has no TypedEdge (it was not resolved before `install!`)"
    elseif e.kind === :typed_edge
        "TypedEdge type unknown at `install!`"
    elseif e.kind === :typed_edge_values
        "Any-typed input or output value types of this edge unknown at `install!`"
    elseif e.kind === :input
        "Input with callback, value or output type unknown at `install!`"
    elseif e.kind === :observable
        "graph observable type unknown at `install!`"
    elseif e.kind === :select
        "select/ifelse edge with output or choice type unknown at `install!`"
    elseif e.kind === :other_edge
        "unknown AbstractEdge subtype"
    else
        string(e.kind)
    end
    print(io, msg)
    isempty(string(e.name)) || print(io, "\n  at: ", e.name)
    isnothing(e.got) || print(io, "\n  got: ", e.got)
    isnothing(e.expected) || print(io, "\n  types seen by `install!`: ", e.expected)
    return
end

"""
    Shapes

The types collected from a set of graphs by [`collect_shapes`](@ref).
"""
struct Shapes
    graphs::Vector{ComputeGraph}
    edges::Vector{ComputeEdge{ComputeGraph}}
    inputs::Vector{Input{ComputeGraph}}
    # TypedEdge type => set of (input value types, output value types, output names).
    # The value types are `nothing` for slots with concrete `RefValue` types
    typed_edges::Dict{Type, Set{Any}}
    # (callback type, value type, output RefValue type)
    input_calls::Set{Tuple{Type, Type, Type}}
    input_value_types::Set{Type}
    # input name => value types (for error messages)
    input_types_by_name::Dict{Symbol, Set{Type}}
    # abstractly typed RefValue type => value types
    abstract_refs::Dict{Type, Set{Type}}
    # (Observable type, RefValue type of the node)
    observables::Set{Tuple{Type, Type}}
    # (output RefValue type, choice RefValue type) of select/ifelse edges
    selections::Set{Tuple{Type, Type}}
    # edges that could not be resolved / typed (callback types)
    skipped::Vector{Any}
end

# The concrete members of `T` if it is a small `Union` of concrete types, else `nothing`
function union_members(@nospecialize(T))
    T isa Union || return nothing
    members = Base.uniontypes(T)
    (length(members) <= MAX_UNION_MEMBERS && all(isconcretetype, members)) || return nothing
    return members
end
const MAX_UNION_MEMBERS = 4

# `nothing` for concretely typed slots, the slot's element type for small Unions of
# concrete types (so values may switch between its members), else the type of the
# value seen at `install!`
function slot_type(ref::RefValue)
    T = eltype(ref)
    isconcretetype(T) && return nothing
    isnothing(union_members(T)) || return T
    return isassigned(ref) ? typeof(ref[]) : Any
end

"""
    track_graphs!()

Starts recording every `ComputeGraph` constructed from now on, until
[`install!`](@ref) succeeds or [`untrack!`](@ref) is called. `install!` uses the
recorded graphs to find the graph which created an Observable (with
`get_observable!`) that a collected graph is fed by, since the Observable has no
reference to it. Call this before building the graphs. Meant for build time only:
the recorded graphs are kept alive until tracking stops.
"""
function track_graphs!()
    ComputePipeline.TRACK_GRAPHS[] = true
    return
end

"""
    untrack!()

Stops recording graphs (see [`track_graphs!`](@ref)) and forgets the recorded ones.
"""
function untrack!()
    ComputePipeline.TRACK_GRAPHS[] = false
    @lock ComputePipeline.TRACKED_GRAPHS_LOCK empty!(ComputePipeline.TRACKED_GRAPHS)
    return
end

"""
    istracking()

Whether graphs are being recorded (see [`track_graphs!`](@ref)).
"""
istracking() = ComputePipeline.TRACK_GRAPHS[]

# Graph observable => the graph which created it with `get_observable!`, for the
# graphs recorded by `track_graphs!`. Reads their `observables`, relying on
# `install!`'s precondition that no other task modifies graphs meanwhile.
function observable_producers()
    graphs = @lock ComputePipeline.TRACKED_GRAPHS_LOCK copy(ComputePipeline.TRACKED_GRAPHS)
    producers = IdDict{Observable, ComputeGraph}()
    for graph in graphs, obs in values(graph.observables)
        producers[obs] = graph
    end
    return producers
end

function find_graphs!(graphs::IdDict{ComputeGraph, Nothing}, graph::ComputeGraph)
    return find_graphs!(graphs, graph, observable_producers())
end

function find_graphs!(graphs::IdDict{ComputeGraph, Nothing}, graph::ComputeGraph, producers)
    haskey(graphs, graph) && return graphs
    graphs[graph] = nothing
    for node in values(graph.outputs)
        hasparent(node) || continue
        edge = node.parent
        edge isa ComputeEdge || continue
        # parent graphs
        for input in edge.inputs
            hasparent(input) && find_graphs!(graphs, ComputePipeline.parent_graph(input.parent), producers)
        end
        # child graphs
        for dep in edge.dependents
            find_graphs!(graphs, ComputePipeline.parent_graph(dep), producers)
        end
    end
    for input in values(graph.inputs), dep in input.dependents
        find_graphs!(graphs, ComputePipeline.parent_graph(dep), producers)
    end
    # graphs connected through Observables: graphs fed by the same Observables
    # (`add_input!(graph, key, ::Observable)`), the graphs producing them and the
    # graphs fed by Observables of this graph's nodes (`get_observable!`)
    for of in graph.observerfunctions
        of.f isa ComputePipeline.ObservableInputUpdater || continue
        find_observable_graphs!(graphs, of.observable, producers)
        haskey(producers, of.observable) && find_graphs!(graphs, producers[of.observable], producers)
    end
    foreach(obs -> find_observable_graphs!(graphs, obs, producers), values(graph.observables))
    return graphs
end

function find_observable_graphs!(graphs::IdDict{ComputeGraph, Nothing}, obs, producers)
    for (_, listener) in Observables.listeners(obs)
        listener isa ComputePipeline.ObservableInputUpdater && find_graphs!(graphs, listener.graph, producers)
    end
    return graphs
end

function find_graphs!(graphs::IdDict{ComputeGraph, Nothing}, root::Computed)
    hasparent(root) && find_graphs!(graphs, ComputePipeline.parent_graph(root.parent))
    return graphs
end
function find_graphs!(::IdDict{ComputeGraph, Nothing}, root)
    throw(ArgumentError("Expected a ComputeGraph or Computed, got $(typeof(root))"))
end

is_select_edge(edge::ComputeEdge) = edge.callback === select || edge.callback === ifelse

"""
    prepare!(graphs; resolve = true)

Makes sure every edge of the given graphs has its `TypedEdge`. Edges which were
resolved before get their `TypedEdge` built from their current values, exactly
like their next resolve would. Unresolved nodes are resolved first if
`resolve = true`. Returns the edges which could not be prepared.
"""
function prepare!(graphs; resolve::Bool = true)
    skipped = ComputeEdge{ComputeGraph}[]
    for graph in graphs
        if resolve
            for input in values(graph.inputs)
                isdefined(input.output, :value) || ComputePipeline.resolve!(input.output)
            end
        end
        for node in values(graph.outputs)
            hasparent(node) || continue
            edge = node.parent
            edge isa ComputeEdge{ComputeGraph} || continue
            isassigned(edge.typed_edge) && continue
            if is_select_edge(edge)
                # select/ifelse edges have no TypedEdge, they only need values
                resolve && !ComputePipeline.is_initialized(node) && ComputePipeline.resolve!(node)
                continue
            end
            if !edge.resolved_once[] && resolve
                try
                    ComputePipeline.resolve!(node)
                catch e
                    @warn "StaticDispatch: could not resolve $(node.name)" exception = e
                end
            end
            if edge.resolved_once[] && !isassigned(edge.typed_edge)
                @lock ComputePipeline.lock_for(graph) edge.typed_edge[] = ComputePipeline.TypedEdge_no_call(edge)
            end
            isassigned(edge.typed_edge) || (edge in skipped) || push!(skipped, edge)
        end
    end
    return skipped
end

# Edges (and Inputs) which can become dirty if the given inputs are updated
function live_edges(inputs)
    live = IdDict{AbstractEdge, Nothing}()
    function mark!(edge)
        haskey(live, edge) && return
        live[edge] = nothing
        foreach(mark!, edge.dependents)
        return
    end
    for x in inputs
        if x isa Computed
            hasparent(x) && mark!(x.parent)
        elseif x isa AbstractEdge
            mark!(x)
        else
            throw(ArgumentError("Expected an Input, ComputeEdge or Computed, got $(typeof(x))"))
        end
    end
    return live
end

"""
    observable_inputs(roots...)

Returns the `Input`s of all graphs connected to `roots` which are fed by an
`Observable` through `add_input!(graph, key, ::Observable)`. Pass them as
`inputs` to [`install!`](@ref) if the graphs are only updated through these
Observables at runtime.
"""
function observable_inputs(roots...)
    found = IdDict{ComputeGraph, Nothing}()
    foreach(root -> find_graphs!(found, root), roots)
    inputs = Input{ComputeGraph}[]
    for graph in keys(found), of in graph.observerfunctions
        updater = of.f
        if updater isa ComputePipeline.ObservableInputUpdater && haskey(updater.graph.inputs, updater.key)
            input = updater.graph.inputs[updater.key]
            any(x -> x === input, inputs) || push!(inputs, input)
        end
    end
    return inputs
end

# Edges (and Inputs) the given nodes depend on
function ancestor_edges(outputs)
    found = IdDict{AbstractEdge, Nothing}()
    function mark!(node::Computed)
        hasparent(node) || return
        edge = node.parent
        haskey(found, edge) && return
        found[edge] = nothing
        edge isa ComputeEdge && foreach(mark!, edge.inputs)
        return
    end
    foreach(mark!, outputs)
    return found
end

"""
    collect_shapes(roots...; inputs = nothing, outputs = nothing, prepare = true, resolve = true)

Collects every `ComputeGraph` connected to the given graphs or nodes and the
types used by their edges, inputs, nodes and observables. With `prepare = true`
[`prepare!`](@ref) runs first.

If `inputs` is given (`Input`s or nodes), only the edges downstream of them are
included. Other edges can not become dirty through updates of these inputs, so
they never run their callbacks and don't need to be compiled. Similarly, if
`outputs` is given (nodes), only edges these nodes depend on are included. Note
that this misses dependencies of callbacks which read other nodes directly.
"""
function collect_shapes(
        roots...; inputs = nothing, outputs = nothing, prepare::Bool = true, resolve::Bool = true
    )
    found = IdDict{ComputeGraph, Nothing}()
    foreach(root -> find_graphs!(found, root), roots)
    graphs = collect(keys(found))
    istracking() || warn_unknown_producers(graphs)
    skipped = prepare ? prepare!(graphs; resolve) : ComputeEdge{ComputeGraph}[]
    isempty(graphs) && return shapes_of(graphs, skipped, inputs, outputs)
    # `lock_for` locks a graph and all graphs connected to it
    return @lock ComputePipeline.lock_for(first(graphs)) shapes_of(graphs, skipped, inputs, outputs)
end

# Names of the inputs fed by an Observable which none of `graphs` created. Either a
# plain Observable or one of a graph not found (without `track_graphs!`).
function unknown_producer_inputs(graphs)
    known = IdDict{Observable, Nothing}()
    for graph in graphs, obs in values(graph.observables)
        known[obs] = nothing
    end
    names = Symbol[]
    for graph in graphs, of in graph.observerfunctions
        updater = of.f
        if updater isa ComputePipeline.ObservableInputUpdater && !haskey(known, of.observable)
            updater.key in names || push!(names, updater.key)
        end
    end
    return names
end

function warn_unknown_producers(graphs)
    names = unknown_producer_inputs(graphs)
    isempty(names) && return
    @warn """StaticDispatch: the inputs $(join(names, ", ")) are fed by Observables which no graph \
        found by `install!` created. If one comes from `get_observable!` of another graph, that graph is \
        missed: pass it to `install!` or call `StaticDispatch.track_graphs!()` before building the graphs. \
        Plain Observables need neither."""
    return
end

function shapes_of(graphs::Vector{ComputeGraph}, skipped, inputs, outputs)
    live = isnothing(inputs) ? nothing : live_edges(inputs)
    needed = isnothing(outputs) ? nothing : ancestor_edges(outputs)
    islive(edge) = (isnothing(live) || haskey(live, edge)) && (isnothing(needed) || haskey(needed, edge))

    shapes = Shapes(
        graphs, ComputeEdge{ComputeGraph}[], Input{ComputeGraph}[],
        Dict{Type, Set{Any}}(), Set{Tuple{Type, Type, Type}}(), Set{Type}(), Dict{Symbol, Set{Type}}(),
        Dict{Type, Set{Type}}(), Set{Tuple{Type, Type}}(), Set{Tuple{Type, Type}}(),
        Any[typeof(e.callback) for e in skipped]
    )

    for graph in graphs
        for input in values(graph.inputs)
            push!(shapes.inputs, input)
            islive(input) || continue
            push!(shapes.input_value_types, typeof(input.value))
            push!(get!(Set{Type}, shapes.input_types_by_name, input.name), typeof(input.value))
            if isdefined(input.output, :value)
                push!(shapes.input_calls, (typeof(input.f), typeof(input.value), typeof(input.output.value)))
            end
        end
        for node in values(graph.outputs)
            hasparent(node) && !islive(node.parent) && continue
            if isdefined(node, :value) && isassigned(node.value) && !isconcretetype(eltype(node.value))
                push!(get!(Set{Type}, shapes.abstract_refs, typeof(node.value)), typeof(node.value[]))
            end
            hasparent(node) || continue
            edge = node.parent
            (edge isa ComputeEdge{ComputeGraph} && node.parent_idx == 1) || continue
            push!(shapes.edges, edge)
            if is_select_edge(edge)
                output = edge.outputs[1]
                isdefined(output, :value) || continue
                for choice in edge.inputs[2:end]
                    isdefined(choice, :value) || continue
                    push!(shapes.selections, (typeof(output.value), typeof(choice.value)))
                end
                continue
            end
            isassigned(edge.typed_edge) || continue
            te = edge.typed_edge[]
            ins = map(slot_type, Tuple(te.inputs))
            outs = map(slot_type, Tuple(te.outputs))
            outnames = Tuple(n.name for n in te.output_nodes)
            push!(get!(Set{Any}, shapes.typed_edges, typeof(te)), (ins, outs, outnames))
        end
        for (key, obs) in graph.observables
            # (other code may cache Observables under keys which are not nodes)
            node = get(graph.outputs, key, nothing)
            isnothing(node) && continue
            hasparent(node) && !islive(node.parent) && continue
            isdefined(node, :value) && push!(shapes.observables, (typeof(obs), typeof(node.value)))
        end
    end
    return shapes
end

function Base.show(io::IO, ::MIME"text/plain", s::Shapes)
    println(io, "StaticDispatch.Shapes:")
    println(io, "  graphs: ", length(s.graphs), ", edges: ", length(s.edges), ", inputs: ", length(s.inputs), " (all, incl. not live)")
    println(io, "  TypedEdge types: ", length(s.typed_edges), " (", sum(length, values(s.typed_edges); init = 0), " slot variants)")
    println(io, "  input calls: ", length(s.input_calls), ", input value types: ", length(s.input_value_types))
    println(io, "  Any-typed nodes: ", length(s.abstract_refs), " RefValue types, observables: ", length(s.observables))
    println(io, "  select/ifelse (output, choice) types: ", length(s.selections))
    print(io, "  edges without TypedEdge: ", length(s.skipped))
    return
end

# Fold `branches` (pairs of condition => body) into an if-elseif chain ending in `fallback`
function isa_chain(branches, fallback)
    ex = fallback
    for (cond, body) in Iterators.reverse(branches)
        ex = Expr(:if, cond, body, ex)
    end
    return ex
end

# `throw(StaticDispatchError(kind, name, got, expected))`. `name` and `got` are
# expressions evaluated at runtime, `expected` is a value known at `install!`.
# Lists of runtime types are built with `any_vector`: a tuple of them (also the
# varargs tuple of `Any[a, b]`) would have an abstract type, which closed-world
# compilers may not support (e.g. WasmCodegen).

# `Vector{Any}` of the values of `exprs`, built with `push!`
function any_vector(exprs)
    v = gensym(:types)
    return Expr(:let, :($v = $Any[]), Expr(:block, [:(push!($v, $x)) for x in exprs]..., v))
end
function fail(kind::Symbol, name = QuoteNode(Symbol("")), got = nothing, expected = nothing)
    return :(throw($StaticDispatchError($(QuoteNode(kind)), $name, $got, $expected)))
end

slot_typeof(ref::RefValue) = isassigned(ref) ? typeof(ref[]) : Union{}

# `ref[]::T` if the slot is Any-typed, else `ref[]`
slot_value(ref, T) = T === nothing ? :($ref[]) : :($ref[]::$T)

function slot_conditions(refs, types)
    conds = Any[]
    for (ref, T) in zip(refs, types)
        T === nothing || push!(conds, :($ref[] isa $T))
    end
    return conds
end

and_all(conds) = isempty(conds) ? true : foldl((a, b) -> :($a && $b), conds)

function typed_edge_method(shapes::Shapes)
    branches = Any[]
    for (T, variants) in shapes.typed_edges
        # TypedEdge{InputTuple, OutputTuple, F}
        IT, OT, F = T.parameters
        if F === typeof(compute_identity) || all(v -> all(isnothing, v[1]) && all(isnothing, v[2]), variants)
            # nothing Any-typed, the existing method is type stable
            push!(branches, :(te isa $T) => :(ComputePipeline.locked_resolve!(te::$T)))
            continue
        end
        innames = fieldnames(IT)
        sub = Any[]
        for (ins, outs, outnames) in variants
            inrefs = [:(e.inputs[$i]) for i in eachindex(innames)]
            outrefs = [:(e.outputs[$i]) for i in eachindex(outnames)]
            conds = vcat(slot_conditions(inrefs, ins), slot_conditions(outrefs, outs))
            if !(OT <: NamedTuple) # output names are not part of the type
                append!(conds, [:(e.output_nodes[$i].name === $(QuoteNode(n))) for (i, n) in enumerate(outnames)])
            end
            cond = and_all(conds)
            invals = Expr(:tuple, [slot_value(r, t) for (r, t) in zip(inrefs, ins)]...)
            outvals = Expr(:tuple, [slot_value(r, t) for (r, t) in zip(outrefs, outs)]...)
            push!(
                sub, cond => :(
                    ComputePipeline.resolve_with_values!(
                        e, NamedTuple{$innames}($invals), NamedTuple{$outnames}($outvals)
                    )
                )
            )
        end
        # value types of all slots for the error message
        got = any_vector(
            vcat(
                [:($slot_typeof(e.inputs[$i])) for i in eachindex(innames)],
                [:($slot_typeof(e.outputs[$i])) for i in 1:fieldcount(OT)],
            )
        )
        expected = Tuple((v[1], v[2]) for v in variants)
        body = quote
            e = te::$T
            any(e.inputs_dirty) || return
            $(isa_chain(sub, fail(:typed_edge_values, :(e.output_nodes[1].name), got, expected)))
        end
        push!(branches, :(te isa $T) => body)
    end
    return :(
        function ComputePipeline.resolve_edge_callback!(edge::ComputeEdge{ComputeGraph})
            isassigned(edge.typed_edge) ||
                $(fail(:untyped_edge, :(edge.outputs[1].name), :(typeof(edge.callback))))
            te = edge.typed_edge[]
            $(isa_chain(branches, fail(:typed_edge, :(edge.outputs[1].name), :(typeof(te)))))
            return
        end
    )
end

function input_method(shapes::Shapes)
    # input name => value types seen, for error messages
    expected = Dict{Symbol, Any}(k => Tuple(v) for (k, v) in shapes.input_types_by_name)
    branches = Any[]
    for (F, V, R) in shapes.input_calls
        cond = :(f isa $F && value isa $V && output.value isa $R)
        body = :((output.value::$R)[] = ComputePipeline.deref((f::$F)(value::$V)))
        push!(branches, cond => body)
    end
    return :(
        function ComputePipeline.update_input_output!(input::Input{ComputeGraph})
            f = input.f
            value = input.value
            output = input.output
            isdefined(output, :value) || $(fail(:input, :(input.name), any_vector([:(typeof(f)), :(typeof(value)), nothing])))
            $(
                isa_chain(
                    branches, fail(
                        :input, :(input.name), any_vector([:(typeof(f)), :(typeof(value)), :(typeof(output.value))]),
                        :(get($expected, input.name, nothing))
                    )
                )
            )
            return
        end
    )
end

# Whether `is_same(::A, ::B)` calls a method other than the fallback for values of
# unrelated types, which returns `false`
function has_is_same_method(@nospecialize(A), @nospecialize(B))
    A === B && return true
    m = try
        which(ComputePipeline.is_same, Tuple{A, B})
    catch
        return true # e.g. ambiguous, the generated call throws like the native one
    end
    return m !== which(ComputePipeline.is_same, Tuple{Any, Any})
end

# `return is_same(old, new)` with static calls for every pair of the concrete `types`
# for which `is_same` has a method (e.g. `Vector{Int}` and `Vector{Float64}`), and
# `return false` for other values, like the fallback method of `is_same`
function is_same_chain(old::Symbol, new::Symbol, types, name)
    types = filter(isconcretetype, collect(Type, types))
    outer = Any[]
    pairs = 0
    for A in types
        inner = Any[]
        # same type first, it's the common case
        for B in sort(types; by = B -> B !== A)
            has_is_same_method(A, B) || continue
            pairs += A !== B
            push!(inner, :($new isa $B) => :(return ComputePipeline.is_same($old::$A, $new::$B)))
        end
        push!(outer, :($old isa $A) => isa_chain(inner, :(return false)))
    end
    if pairs > MAX_IS_SAME_PAIRS
        @warn "StaticDispatch: $name compares $pairs pairs of different value types ($(length(types)) types)"
    end
    return isa_chain(outer, :(return false))
end
# Above this number of pairs of different types in one `is_same` chain, `install!` warns
const MAX_IS_SAME_PAIRS = 64

function is_same_input_method(shapes::Shapes)
    # Values of other types are "not the same", i.e. the input updates
    return :(
        function ComputePipeline.is_same_input_value(input::Input{ComputeGraph}, @nospecialize(value))
            old = input.value
            $(is_same_chain(:old, :value, shapes.input_value_types, "is_same_input_value"))
        end
    )
end

function is_same_cached_methods(shapes::Shapes)
    methods = Any[]
    for (R, Vs) in shapes.abstract_refs
        # all members of small Union slots, not just the ones seen at `install!`
        members = union_members(eltype(R))
        push!(
            methods, :(
                function ComputePipeline.is_same_cached(ref::$R, @nospecialize(new))
                    old = ref[]
                    $(is_same_chain(:old, :new, isnothing(members) ? Vs : members, "is_same_cached(::$R)"))
                end
            )
        )
    end
    return methods
end

function select_method(shapes::Shapes)
    branches = Any[]
    for (R, C) in shapes.selections
        cond = :(output.value isa $R && choice isa $C)
        body = quote
            out = output.value::$R
            new_value = (choice::$C)[]
            output.dirty = !ComputePipeline.is_same(out[], new_value)
            out[] = new_value
            return
        end
        push!(branches, cond => body)
    end
    return :(
        function ComputePipeline.forward_selected!(output::Computed, @nospecialize(choice::RefValue))
            ComputePipeline.is_initialized(output) || $(fail(:select, :(output.name)))
            $(
                isa_chain(
                    branches,
                    fail(:select, :(output.name), any_vector([:(typeof(output.value)), :(typeof(choice))]), Tuple(shapes.selections))
                )
            )
        end
    )
end

function observable_method(shapes::Shapes)
    branches = Any[]
    for (O, R) in shapes.observables
        cond = :(obs isa $O && node.value isa $R)
        body = quote
            ComputePipeline.resolve!(node)
            return ComputePipeline.sync_observable_value!(obs::$O, (node.value::$R)[], use_deepcopy)
        end
        push!(branches, cond => body)
    end
    return :(
        function ComputePipeline.sync_observable!(@nospecialize(obs::Observable), node::Computed, use_deepcopy::Bool)
            $(
                isa_chain(
                    branches,
                    fail(:observable, :(node.name), any_vector([:(typeof(obs)), :(typeof(node.value))]), Tuple(shapes.observables))
                )
            )
        end
    )
end

"""
    generate(shapes::Shapes)
    generate(roots...; kwargs...)

Returns the method definitions [`install!`](@ref) evaluates. The expression
interpolates type objects, so it must be evaluated, not printed.
"""
function generate(shapes::Shapes)
    return Expr(
        :block,
        typed_edge_method(shapes),
        input_method(shapes),
        is_same_input_method(shapes),
        is_same_cached_methods(shapes)...,
        observable_method(shapes),
        select_method(shapes),
        :(
            ComputePipeline.other_edge(f, @nospecialize(edge::AbstractEdge)) =
                $(fail(:other_edge, QuoteNode(Symbol("")), :(typeof(edge))))
        ),
        # `ResolveException{typeof(e)}` needs a dynamic constructor call. The
        # exceptions ComputePipeline throws itself keep their concrete type, others
        # are wrapped as `ResolveException{Exception}` (`showerror` is the same).
        :(
            function ComputePipeline.resolve_exception(computed::Computed, @nospecialize(e))
                if e isa SelectException
                    return ComputePipeline.ResolveException{SelectException}(computed, e)
                elseif e isa StaticDispatchError
                    return ComputePipeline.ResolveException{StaticDispatchError}(computed, e)
                elseif e isa Exception
                    return ComputePipeline.ResolveException{Exception}(computed, e)
                else
                    return e
                end
            end
        ),
        nothing
    )
end
generate(roots...; kwargs...) = generate(collect_shapes(roots...; kwargs...))

# Methods added by `install!`. `install!`/`uninstall!` are build-time operations
# which require that no other task uses graphs meanwhile (see `install!`).
# `INSTALL_LOCK` only keeps concurrent `install!`/`uninstall!` calls from
# interleaving. It is only held while methods are evaluated or deleted, never while
# taking a graph lock (`lock_for`) or running graph code (`prepare!` may run
# callbacks and Observable listeners), and `isinstalled` reads `IS_INSTALLED`
# without locking, so graph code never waits on `INSTALL_LOCK`.
const INSTALLED = Method[]
const INSTALL_LOCK = ReentrantLock()
const IS_INSTALLED = Threads.Atomic{Bool}(false)

"""
    install!(roots...; inputs = nothing, outputs = nothing, prepare = true, resolve = true, mod = StaticDispatch)

Collects the types used by all graphs connected to `roots` (graphs or nodes)
and adds statically dispatching methods for them to ComputePipeline's hook
functions (evaluated in module `mod`). Returns the collected [`Shapes`](@ref).
See [`collect_shapes`](@ref) for `inputs` and `outputs` (restricting the
generated code to edges between the inputs updated and the nodes read at
runtime) and [`prepare!`](@ref).

Graphs are connected through edges between them and through Observables they
share as inputs (`add_input!(graph, key, ::Observable)`). An Observable from
`get_observable!` also connects the graph which created it with the graphs it
feeds. From the creating graph to the fed graphs this always works, but in the
other direction the Observable has no reference to its graph: that graph is only
found if it was constructed after [`track_graphs!`](@ref), or if it is passed in `roots`.
Without tracking, `install!` warns about inputs fed by Observables which none of
the collected graphs created. Observables derived from these with `map` or
`connect!` are not followed.

Typical build-time use: `track_graphs!()`, build the graphs (e.g. a scene),
`install!(roots...)`, then compile. A successful `install!` stops tracking and
forgets the recorded graphs (like [`untrack!`](@ref)).

`install!` and [`uninstall!`](@ref) are build-time operations: while they run,
no other task may update, resolve, build or modify any `ComputeGraph` (including
`get_observable!` and updates through Observables). `install!` reads the graphs
before it evaluates the methods, and the methods are added one at a time, so a
concurrent update could change types in between or run with only some of the
methods installed. This is not checked. Callbacks run by `install!` itself (when
[`prepare!`](@ref) resolves nodes) may call [`isinstalled`](@ref), which does not lock.

Values of different types which `is_same` compares with a method other than its
`false` fallback (e.g. `Vector{Int}` and `Vector{Float64}`) get one branch per
pair, so these grow quadratically with the number of such types. A warning is
shown above $(MAX_IS_SAME_PAIRS) pairs in one method.

Call this once, after all graphs are built and resolved, before compiling. The
graphs keep working natively afterwards, but throw a [`StaticDispatchError`](@ref)
for types or edges not seen by `install!`. Note that the added methods apply to
every `ComputeGraph` in the session, including graphs not connected to `roots`.

Modifying the graphs after `install!` is not supported: adding, removing or
replacing inputs or edges (e.g. with `register_computation!`, `delete!` or an
edge modification API) is not seen by the installed methods.
"""
function install!(roots...; mod::Module = StaticDispatch, kwargs...)
    check_not_installed()
    # without `INSTALL_LOCK`: this takes the graph lock and may run callbacks
    # (precondition: no other task uses the graphs until `install!` returns)
    shapes = collect_shapes(roots...; kwargs...)
    defs = generate(shapes).args
    @lock INSTALL_LOCK begin
        check_not_installed()
        eval_tracked!(mod, defs)
    end
    untrack!()
    return shapes
end

function check_not_installed()
    isinstalled() && error("StaticDispatch is already installed. Call `uninstall!()` first.")
    return
end

# Evaluates the method definitions `defs` in `mod` and records every method they add
# in `INSTALLED`, also if one of them throws, so `uninstall!` can remove them.
function eval_tracked!(mod::Module, defs)
    @lock INSTALL_LOCK begin
        try
            for def in defs
                (def isa Expr) || continue
                before = Set{Method}(installed_candidates())
                try
                    Core.eval(mod, def)
                finally
                    for m in installed_candidates()
                        m in before || push!(INSTALLED, m)
                    end
                end
            end
        finally
            IS_INSTALLED[] = !isempty(INSTALLED)
        end
    end
    return
end

function installed_candidates()
    fs = (
        ComputePipeline.resolve_edge_callback!,
        ComputePipeline.update_input_output!, ComputePipeline.is_same_input_value,
        ComputePipeline.is_same_cached, ComputePipeline.sync_observable!,
        ComputePipeline.other_edge, ComputePipeline.resolve_exception,
        ComputePipeline.forward_selected!,
    )
    return Method[m for f in fs for m in methods(f)]
end

"""
    uninstall!()

Removes the methods added by [`install!`](@ref), returning to the dynamic
behaviour. Mainly meant for tests and interactive use; it relies on
`Base.delete_method`, which is internal to Julia. Like `install!`, it requires
that no other task uses graphs while it runs.
"""
function uninstall!()
    @lock INSTALL_LOCK begin
        foreach(Base.delete_method, INSTALLED)
        empty!(INSTALLED)
        IS_INSTALLED[] = false
    end
    return
end

"""
    isinstalled()

Whether [`install!`](@ref) added methods which were not removed by
[`uninstall!`](@ref) yet. Does not lock, so it can be called from graph callbacks.
"""
isinstalled() = IS_INSTALLED[]

end
