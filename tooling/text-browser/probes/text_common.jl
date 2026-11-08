# The FreeType-independent overlays of the text probes (from capmap's text_overrides.jl, unchanged): the parts that make
# `text!` compile under verify = :error that have nothing to do with fonts. Wasm only (overlays).
module TextCommon
using WasmCodegen, Makie
const WASM = WasmCodegen.Runtime.WASM_METHODS

# (a)/(b) WGLMakie/src/plot-primitives.jl:443 `glyph_data` is a `Dict{Symbol, Any}`, which ComputePipeline compares with
# `isequal` over `Any` values (ComputePipeline.jl:1199). Treated as always changed (the update is resent).
Base.Experimental.@overlay WASM Makie.ComputePipeline.is_same(old::Dict{Symbol, Any}, new::Dict{Symbol, Any}) = false

@noinline no_specs() = error("text: layout specs (LaTeX rules, text_handler plots) are not supported in this build")
"""
(b) Text without layout specs: Makie/src/basic_recipes/text.jl:742 places each spec of the plotlist child (`PlotSpec`
with `Dict{Symbol,Any}` keywords, `symbol_to_plot`): that is creating plots at run time, compiled even when the
specs are empty (plain strings and `rich` text have none). Called at build time with the program's text plots.
"""
function no_text_specs!(plots...)
    for p in plots
        F = typeof(p.attributes[:_placed_text_specs].parent.callback.user_func)
        @eval Base.Experimental.@overlay WASM (f::$F)(specs::Vector{Makie.PlotSpec}, rest...) =
            isempty(specs) ? Makie.PlotSpec[] : no_specs()
    end
    return
end
# (the plotlist child's `converted` observable is synced with a `deepcopy` of its `Vector{PlotSpec}`,
# ComputePipeline.jl:683: always empty here)
Base.Experimental.@overlay WASM function Makie.ComputePipeline.sync_observable_value!(
        obs::Makie.Observable{Tuple{Vector{Makie.PlotSpec}}}, val::Tuple{Vector{Makie.PlotSpec}}, use_deepcopy::Bool)
    (isempty(val[1]) && isempty(obs.val[1])) || no_specs()
    return false
end

# (a) Makie/src/basic_recipes/text.jl:74-79 the text argument callback tests `args isa Tuple{<:Union{AbstractString,
# RichText}}` etc.: these `Tuple{<:...}` types are built at run time (`Core._typevar`, which WasmCodegen cannot
# compile: class (c)). The same tests as methods, whose signatures are built when they are defined:
const StrLike = Union{AbstractString, Makie.RichText}
is_str(::Tuple{<:StrLike}) = true
is_str(@nospecialize(x)) = false
is_strvec(::Tuple{<:AbstractVector{<:StrLike}}) = true
is_strvec(@nospecialize(x)) = false
is_pairvec(::Tuple{<:AbstractVector{<:Tuple{<:Any, <:Makie.VecTypes}}}) = true
is_pairvec(@nospecialize(x)) = false
function text_args(inputs, changed)
    a_pos, a_text, args... = values(inputs)
    _, text_changed, args_changed... = values(changed)
    if is_str(args)
        return ((a_pos,), Makie.text_update([args[1]], args_changed[1]))
    elseif is_strvec(args)
        return ((a_pos,), Makie.text_update(args[1], args_changed[1]))
    elseif is_pairvec(args)
        return ((last.(args[1]),), Makie.text_update(first.(args[1]), args_changed[1]))
    else
        return (args, Makie.text_update(Makie.to_string_arr(a_text), text_changed))
    end
end
"Called at build time with the program's text plots."
function typed_text_args!(plots...)
    for p in plots
        cb = p.attributes[:_positions].parent.callback
        F = typeof(cb)
        @eval Base.Experimental.@overlay WASM (f::$F)(inputs, changed, cached) = text_args(inputs, changed)
    end
    return
end
end
