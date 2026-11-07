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
graph = ComputeGraph()
add_input!(graph, :a, 1.0)
map!(x -> 2x, graph, :a, :b)
ComputePipeline.StaticDispatch.install!(graph)
# compile entry points which use `graph`
```
"""
module StaticDispatch

using ..ComputePipeline: ComputePipeline, ComputeGraph, ComputeEdge, Input, Computed,
    TypedEdge, AbstractEdge, GLOBAL_LOCK, hasparent, select, compute_identity
using Base: RefValue
using Observables: Observable

"""
    StaticDispatchError(kind::Symbol)

Thrown by the methods added by [`install!`](@ref) when the graph reaches a state
that did not exist when `install!` was called, e.g. an input set to a value of
a new type or an edge that was never resolved.
"""
struct StaticDispatchError <: Exception
    kind::Symbol
end

function Base.showerror(io::IO, e::StaticDispatchError)
    print(io, "StaticDispatchError: ")
    msg = if e.kind === :untyped_edge
        "edge has no TypedEdge (it was not resolved before `install!`)"
    elseif e.kind === :typed_edge
        "TypedEdge type or Any-typed node value type unknown at `install!`"
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
    # abstractly typed RefValue type => value types
    abstract_refs::Dict{Type, Set{Type}}
    # (Observable type, RefValue type of the node)
    observables::Set{Tuple{Type, Type}}
    # (output RefValue type, choice RefValue type) of select/ifelse edges
    selections::Set{Tuple{Type, Type}}
    # edges that could not be resolved / typed (callback types)
    skipped::Vector{Any}
end

function slot_type(ref::RefValue)
    isconcretetype(eltype(ref)) && return nothing
    return isassigned(ref) ? typeof(ref[]) : Any
end

function find_graphs!(graphs::IdDict{ComputeGraph, Nothing}, graph::ComputeGraph)
    haskey(graphs, graph) && return graphs
    graphs[graph] = nothing
    for node in values(graph.outputs)
        hasparent(node) || continue
        edge = node.parent
        edge isa ComputeEdge || continue
        # parent graphs
        for input in edge.inputs
            hasparent(input) && find_graphs!(graphs, ComputePipeline.parent_graph(input.parent))
        end
        # child graphs
        for dep in edge.dependents
            find_graphs!(graphs, ComputePipeline.parent_graph(dep))
        end
    end
    for input in values(graph.inputs), dep in input.dependents
        find_graphs!(graphs, ComputePipeline.parent_graph(dep))
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
                @lock GLOBAL_LOCK edge.typed_edge[] = ComputePipeline.TypedEdge_no_call(edge)
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
    skipped = prepare ? prepare!(graphs; resolve) : ComputeEdge{ComputeGraph}[]
    live = isnothing(inputs) ? nothing : live_edges(inputs)
    needed = isnothing(outputs) ? nothing : ancestor_edges(outputs)
    islive(edge) = (isnothing(live) || haskey(live, edge)) && (isnothing(needed) || haskey(needed, edge))

    shapes = Shapes(
        graphs, ComputeEdge{ComputeGraph}[], Input{ComputeGraph}[],
        Dict{Type, Set{Any}}(), Set{Tuple{Type, Type, Type}}(), Set{Type}(),
        Dict{Type, Set{Type}}(), Set{Tuple{Type, Type}}(), Set{Tuple{Type, Type}}(),
        Any[typeof(e.callback) for e in skipped]
    )

    for graph in graphs
        for input in values(graph.inputs)
            push!(shapes.inputs, input)
            islive(input) || continue
            push!(shapes.input_value_types, typeof(input.value))
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
            node = graph.outputs[key]
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

fail(kind::Symbol) = :(throw($StaticDispatchError($(QuoteNode(kind)))))

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
            push!(branches, :(edge isa $T) => :(ComputePipeline.locked_resolve!(edge::$T)))
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
        body = quote
            e = edge::$T
            any(e.inputs_dirty) || return
            $(isa_chain(sub, fail(:typed_edge)))
        end
        push!(branches, :(edge isa $T) => body)
    end
    return :(
        function ComputePipeline.resolve_typed_edge!(@nospecialize(edge::TypedEdge))
            $(isa_chain(branches, fail(:typed_edge)))
            return
        end
    )
end

function input_method(shapes::Shapes)
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
            isdefined(output, :value) || $(fail(:input))
            $(isa_chain(branches, fail(:input)))
            return
        end
    )
end

function is_same_input_method(shapes::Shapes)
    branches = Any[]
    for V in shapes.input_value_types
        isconcretetype(V) || continue
        push!(branches, :(old isa $V && value isa $V) => :(return ComputePipeline.is_same(old::$V, value::$V)))
    end
    # Values of different types are "not the same", i.e. the input updates
    return :(
        function ComputePipeline.is_same_input_value(input::Input{ComputeGraph}, @nospecialize(value))
            old = input.value
            $(isa_chain(branches, :(return false)))
        end
    )
end

function is_same_cached_methods(shapes::Shapes)
    methods = Any[]
    for (R, Vs) in shapes.abstract_refs
        branches = Any[]
        for V in Vs
            isconcretetype(V) || continue
            push!(branches, :(old isa $V && new isa $V) => :(return ComputePipeline.is_same(old::$V, new::$V)))
        end
        push!(
            methods, :(
                function ComputePipeline.is_same_cached(ref::$R, @nospecialize(new))
                    old = ref[]
                    $(isa_chain(branches, :(return false)))
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
            ComputePipeline.is_initialized(output) || $(fail(:select))
            $(isa_chain(branches, fail(:select)))
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
            $(isa_chain(branches, fail(:observable)))
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
        :(ComputePipeline.resolve_untyped_edge!(edge::ComputeEdge{ComputeGraph}) = $(fail(:untyped_edge))),
        input_method(shapes),
        is_same_input_method(shapes),
        is_same_cached_methods(shapes)...,
        observable_method(shapes),
        select_method(shapes),
        :(ComputePipeline.other_edge(f, @nospecialize(edge::AbstractEdge)) = $(fail(:other_edge))),
        # ResolveException{typeof(e)} needs a dynamic constructor call
        :(
            function ComputePipeline.resolve_exception(computed::Computed, @nospecialize(e))
                return e isa Exception ? ComputePipeline.ResolveException{Exception}(computed, e) : e
            end
        ),
        nothing
    )
end
generate(roots...; kwargs...) = generate(collect_shapes(roots...; kwargs...))

const INSTALLED = Method[]

"""
    install!(roots...; inputs = nothing, outputs = nothing, prepare = true, resolve = true, mod = StaticDispatch)

Collects the types used by all graphs connected to `roots` (graphs or nodes)
and adds statically dispatching methods for them to ComputePipeline's hook
functions (evaluated in module `mod`). Returns the collected [`Shapes`](@ref).
See [`collect_shapes`](@ref) for `inputs` and `outputs` (restricting the
generated code to edges between the inputs updated and the nodes read at
runtime) and [`prepare!`](@ref).

Call this once, after all graphs are built and resolved, before compiling. The
graphs keep working natively afterwards, but throw a [`StaticDispatchError`](@ref)
for types or edges not seen by `install!`. Use [`uninstall!`](@ref) to return
to the dynamic behaviour.
"""
function install!(roots...; mod::Module = StaticDispatch, kwargs...)
    isempty(INSTALLED) || error("StaticDispatch is already installed. Call `uninstall!()` first.")
    shapes = collect_shapes(roots...; kwargs...)
    ex = generate(shapes)
    before = Set{Method}(installed_candidates())
    Core.eval(mod, ex)
    for m in installed_candidates()
        m in before || push!(INSTALLED, m)
    end
    return shapes
end

function installed_candidates()
    fs = (
        ComputePipeline.resolve_typed_edge!, ComputePipeline.resolve_untyped_edge!,
        ComputePipeline.update_input_output!, ComputePipeline.is_same_input_value,
        ComputePipeline.is_same_cached, ComputePipeline.sync_observable!,
        ComputePipeline.other_edge, ComputePipeline.resolve_exception,
        ComputePipeline.forward_selected!,
    )
    return Method[m for f in fs for m in methods(f)]
end

"""
    uninstall!()

Removes the methods added by [`install!`](@ref).
"""
function uninstall!()
    foreach(Base.delete_method, INSTALLED)
    empty!(INSTALLED)
    return
end

isinstalled() = !isempty(INSTALLED)

end
