# Strict ahead-of-time compile check of the polygon triangulation that `poly`, `barplot`, `hist` and `pie` use
# (`Makie.poly_convert`, so `Makie.earcut_triangulate`). Each probe makes the polygons the way its recipe does and
# triangulates them, and WasmCodegen compiles it with the strict `juliac --trim=safe`-like settings
# (`verify = :error`: any statement that is not statically resolved, including a `ccall` to `libearcut`, is an error).
# If `node` (>= 24) is found, the compiled module is run and its checksum of the faces compared with native Julia's.
#
# This is not part of Makie's test suite, as it needs the WasmCodegen toolchain. Run it, with an environment that has
# Makie (and ComputePipeline) developed from this checkout, and WasmCodegen and WasmCompat:
#
#     julia --project=<env> tooling/wasm_strict_check.jl
#
# e.g. `Pkg.develop(path = "Makie"); Pkg.develop(path = "ComputePipeline")` in `<env>` and then
# `Pkg.add(url = "https://github.com/asinghvi17-bot/WasmCodegen.jl")` and the same for WasmCompat. Exits with a non-zero
# status if a probe does not compile, or if its result in Wasm differs from native.

using WasmCodegen, WasmCompat
using Makie
using Makie: Point2, Point2d, Polygon

const GB = Makie.GeometryBasics

# an order-dependent checksum of the faces of meshes (wraps around the same way natively and in Wasm)
function faces_checksum(meshes)::Int
    h = 0
    for m in meshes
        for f in GB.faces(m)
            h = h * 31 + Int(GB.value(f[1]))
            h = h * 31 + Int(GB.value(f[2]))
            h = h * 31 + Int(GB.value(f[3]))
        end
        h = h * 31 + 7
    end
    return h
end

function ngon_points(n::Int, r::Float64, cx::Float64, cy::Float64, sgn::Float64)::Vector{Point2d}
    return [
        Point2d(cx + r * cos(sgn * 2pi * (i - 1) / n), cy + r * sin(sgn * 2pi * (i - 1) / n)) for i in 1:n
    ]
end

# poly: polygons with holes (a square with a hole; a rectangle with 20 holes whose leftmost x are equal; a ring with 100
# points, which triangulates with z-order hashing)
function probe_poly()::Int
    square = Point2d[(0, 0), (10, 0), (10, 10), (0, 10)]
    hole = Point2d[(4, 4), (4, 6), (6, 6), (6, 4)]
    holes = Vector{Point2d}[Point2d[(2, 6i - 4), (2, 6i - 1), (5, 6i - 1), (5, 6i - 4)] for i in 1:20]
    tall = Point2d[(0, 0), (10, 0), (10, 120), (0, 120)]
    ring = Polygon(ngon_points(100, 10.0, 0.0, 0.0, 1.0), [ngon_points(100, 5.0, 0.0, 0.0, -1.0)])
    polys = Polygon{2, Float64}[Polygon(square, [hole]), Polygon(tall, holes), ring]
    return faces_checksum(Makie.poly_convert(polys, identity)) +
        faces_checksum([Makie.poly_convert(polys[1], identity)])
end

# barplot: the rectangles of `Makie.bar_rectangle`, as the recipe makes them
function probe_barplot()::Int
    lims = Makie.Rect2d(Point2d(-1.0e6, -1.0e6), Point2d(2.0e6, 2.0e6))
    xs = [1.0, 2.0, 3.0, 4.0]
    ys = [3.0, -1.0, 2.0, 5.0]
    bars = [Makie.bar_rectangle(identity, xs[i], ys[i], 0.0, 0.8, 0.0, true, lims) for i in 1:4]
    return faces_checksum(Makie.poly_convert(bars, identity))
end

# hist: the bars of a histogram, which `hist` plots with `barplot`
function probe_hist()::Int
    data = [0.1, 0.2, 0.25, 0.7, 0.9, 1.5, 2.0, 0.3, 0.35]
    edges = [0.0, 0.5, 1.0, 1.5, 2.0]
    lims = Makie.Rect2d(Point2d(-1.0e6, -1.0e6), Point2d(2.0e6, 2.0e6))
    bars = Polygon{2, Float64}[]
    for i in 1:(length(edges) - 1)
        count = 0.0
        for d in data
            (edges[i] <= d < edges[i + 1] || (i == length(edges) - 1 && d == edges[end])) && (count += 1)
        end
        push!(
            bars,
            Makie.bar_rectangle(
                identity, (edges[i] + edges[i + 1]) / 2, count, 0.0, edges[i + 1] - edges[i], 0.0, true, lims
            ),
        )
    end
    return faces_checksum(Makie.poly_convert(bars, identity))
end

# pie: the wedges and the ring slices `pie` makes (`Vector{Vector{Point2}}`)
function probe_pie()::Int
    wedges = Vector{Point2{Float64}}[]
    for (sta, en, inner_r) in ((0.0, 2.0, 0.0), (2.0, 4.0, 0.0), (4.0, 6.0, 0.5))
        n = 40
        points = Point2{Float64}[
            Point2(cos(sta + (en - sta) * (i - 1) / (n - 1)), sin(sta + (en - sta) * (i - 1) / (n - 1))) for
                i in 1:n
        ]
        if inner_r != 0
            for i in 1:n
                push!(
                    points,
                    Point2(
                        inner_r * cos(en + (sta - en) * (i - 1) / (n - 1)),
                        inner_r * sin(en + (sta - en) * (i - 1) / (n - 1)),
                    ),
                )
            end
        else
            push!(points, Point2(0.0, 0.0))
        end
        push!(wedges, points)
    end
    return faces_checksum(Makie.poly_convert(wedges, identity))
end

const PROBES = [probe_poly, probe_barplot, probe_hist, probe_pie]
const CONFIG = WasmCodegen.Config(; verify = :error, host = :wasi, trim = :safe, shell_first_mutables = true)

const RUN_MJS = """
import { WASI } from 'node:wasi';
import fs from 'node:fs';
const [file, name] = process.argv.slice(2);
const wasi = new WASI({ version: 'preview1', returnOnExit: true });
const { instance } = await WebAssembly.instantiate(fs.readFileSync(file), wasi.getImportObject());
wasi.initialize(instance);
console.log(String(instance.exports[name]()));
"""

function run_in_node(bytes, name)
    node = Sys.which("node")
    node === nothing && return nothing
    return mktempdir() do dir
        write(joinpath(dir, "probe.wasm"), bytes)
        write(joinpath(dir, "run.mjs"), RUN_MJS)
        out = read(
            `$node --disable-warning=ExperimentalWarning $(joinpath(dir, "run.mjs")) $(joinpath(dir, "probe.wasm")) $name`,
            String,
        )
        return parse(Int, strip(out))
    end
end

function main()
    failed = String[]
    for probe in PROBES
        name = String(nameof(probe))
        native = probe()
        try
            c = WasmCodegen.compile([WasmCodegen.Entry(probe, (); name = name)]; config = CONFIG)
            wasm = run_in_node(c.bytes, name)
            status = if wasm === nothing
                "compiled (no node: not run)"
            elseif wasm == native
                "compiled, same checksum as native"
            else
                "compiled, DIFFERENT checksum"
            end
            println(
                rpad(name, 16),
                length(c.bytes),
                " bytes, ",
                status,
                " (native $native",
                wasm === nothing ? "" : ", wasm $wasm",
                ")",
            )
            wasm !== nothing && wasm != native && push!(failed, name)
        catch e
            println(rpad(name, 16), "FAILED:\n", first(sprint(showerror, e), 4000))
            push!(failed, name)
        end
    end
    isempty(failed) || (println("failed: ", join(failed, ", ")); exit(1))
    return println("all probes compile with verify = :error")
end

main()
