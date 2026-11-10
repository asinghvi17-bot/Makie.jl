using Pkg
M, T, C = ARGS
Pkg.develop([PackageSpec(path=M*"/ComputePipeline"), PackageSpec(path=M*"/Makie"), PackageSpec(path=M*"/WGLMakie"),
             PackageSpec(path=T*"/wc"), PackageSpec(path=T*"/WasmCompat2"), PackageSpec(path=C*"/PureFont")])
Pkg.add(["Observables", "Bonito", "FreeTypeAbstraction", "GeometryBasics"])
Pkg.status()
