using WGLMakie, Makie, Observables, Bonito
using WasmCodegen, WasmCompat
include(joinpath(ENV["CAPMAP_PROBES"], "common.jl"))
include(joinpath(ENV["CAPMAP_PROBES"], "overrides.jl"))
include(abspath(ARGS[1]))
Prog.prepare()
# BFS from the Prog's globals for a TextureAtlas, printing the path
function find(root, target::Type; maxdepth = 14)
    seen = IdDict{Any, Bool}()
    queue = Any[(root, "root")]
    found = String[]
    while !isempty(queue)
        (x, path) = popfirst!(queue)
        x === nothing && continue
        (x isa Number || x isa Symbol || x isa String || x isa DataType || x isa Module || x isa Function) && continue
        (x isa Method || x isa Core.MethodInstance || x isa Core.CodeInstance || x isa Type || x isa Core.TypeName || x isa Ptr || x isa Task || x isa IO) && continue
        isbits(x) && continue
        haskey(seen, x) && continue
        seen[x] = true
        count('/', path) > maxdepth && continue
        if x isa target && length(x) >= 4_000_000
            push!(found, path); length(found) >= 3 && return found
            continue
        end
        if x isa AbstractDict
            for (k, v) in x
                push!(queue, (v, string(path, "/[", k isa Symbol || k isa String ? k : typeof(k), "]")))
            end
        elseif x isa AbstractArray && !(eltype(x) <: Number)
            for (i, v) in enumerate(x)
                i > 50 && break
                push!(queue, (v, string(path, "/[", i, "]")))
            end
        elseif x isa Tuple
            for (i, v) in enumerate(x)
                push!(queue, (v, string(path, "/(", i, ")")))
            end
        elseif isstructtype(typeof(x)) && !(x isa AbstractArray)
            for f in fieldnames(typeof(x))
                isdefined(x, f) || continue
                push!(queue, (getfield(x, f), string(path, "/", f)))
            end
        end
    end
    return found
end
for p in find(Prog.SCENE, AbstractArray{Float16}; maxdepth = 40); println("SCENE => ", p); end
for p in find(Prog.PLOTS, AbstractArray{Float16}; maxdepth = 40); println("PLOTS => ", p); end
println("done scene")
