# julia --project=ENV build.jl PROG.jl OUT.wasm — compile PROG.jl's `Prog.ENTRIES` strictly (WASI, verify=:error, trim=:safe).
using Makie, PureFont, WasmCodegen
include(joinpath(@__DIR__, "font_overrides.jl"))
include(abspath(ARGS[1]))
Prog.prepare()
cfg = WasmCodegen.Config(; host = :wasi, trim = :safe, verify = Symbol(get(ENV, "VERIFY", "error")), on_unsupported = :error, shell_first_mutables = true,
                         (isdefined(Prog, :CONFIG) ? Prog.CONFIG : (;))...)
t = time()
c = try
    WasmCodegen.compile([WasmCodegen.Entry(f, a; name = n) for (f, a, n) in Prog.ENTRIES]; config = cfg)
catch err
    println("COMPILE FAILED after ", round(time() - t; digits = 1), " s")
    open(ARGS[2] * ".errors.txt", "w") do io
        showerror(io, err)
    end
    s = sprint(showerror, err)
    println("error type: ", typeof(err), "; ", count("\nError", "\n" * s), " verifier errors; ", count("\nWarning", "\n" * s), " warnings; size ", length(s))
    exit(2)
end
println("compiled in ", round(time() - t; digits = 1), " s, ", length(c.bytes), " bytes")
rep = isassigned(c.world.trim_report) ? c.world.trim_report[] : ""
println("verifier: ", isempty(rep) ? "clean" : string(count("\nError", "\n" * rep), " errors, ", count("\nWarning", "\n" * rep), " warnings"))
isempty(rep) || write(ARGS[2] * ".verifier.txt", rep)
write(ARGS[2], c.bytes)
