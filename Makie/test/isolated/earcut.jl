# Makie.earcut_triangulate is a pure Julia port of earcut.hpp. It must agree with libearcut
# (GeometryBasics.earcut_triangulate), triangle for triangle.
using Random
using GeometryBasics: value

@testset "earcut" begin
    ngon(n, r, T; ccw = true) = [Point2{T}(r * cos((ccw ? 1 : -1) * 2pi * (i - 1) / n), r * sin((ccw ? 1 : -1) * 2pi * (i - 1) / n)) for i in 1:n]
    star(n, T) = [Point2{T}((iseven(i) ? 0.4 : 1.0) * cos(pi * (i - 1) / n), (iseven(i) ? 0.4 : 1.0) * sin(pi * (i - 1) / n)) for i in 1:(2n)]
    function area_of(rings, faces)
        pts = reduce(vcat, rings)
        tri(f) = (a = pts[value(f[1])]; b = pts[value(f[2])]; c = pts[value(f[3])]; abs((b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2])) / 2)
        return sum(tri, faces; init = 0.0)
    end
    ring_area(r) = abs(sum(i -> r[i][1] * r[mod1(i + 1, length(r))][2] - r[mod1(i + 1, length(r))][1] * r[i][2], eachindex(r))) / 2

    @testset "same faces as libearcut ($T)" for T in (Float32, Float64)
        P(x, y) = Point2{T}(x, y)
        square = [P(0, 0), P(10, 0), P(10, 10), P(0, 10)]
        hole(x, y) = [P(x, y), P(x, y + 1), P(x + 1, y + 1), P(x + 1, y)]
        cases = [
            "triangle" => [[P(0, 0), P(1, 0), P(0, 1)]],
            "square" => [[P(0, 0), P(1, 0), P(1, 1), P(0, 1)]],
            "clockwise square" => [[P(0, 0), P(0, 1), P(1, 1), P(1, 0)]],
            "closed ring" => [[P(0, 0), P(1, 0), P(1, 1), P(0, 1), P(0, 0)]],
            "convex 7-gon" => [ngon(7, 2, T)],
            "convex 500-gon (z-order hashing)" => [ngon(500, 2, T)],
            "L shape" => [[P(0, 0), P(2, 0), P(2, 1), P(1, 1), P(1, 2), P(0, 2)]],
            "star" => [star(12, T)],
            "star with hole" => [star(8, T), ngon(8, 0.2, T; ccw = false)],
            "square with hole" => [square, hole(4, 4)],
            "square with two holes" => [square, hole(2, 2), hole(6, 6)],
            "hole touching the outline" => [square, [P(0, 4), P(1, 4), P(1, 5), P(0, 5)]],
            "20 holes" => [[P(0, 0), P(41, 0), P(41, 10), P(0, 10)], [hole(1.0 + 2 * i, 1.0 + (i % 3) * 2.5) for i in 0:19]...],
            "big ring with big hole (z-order hashing)" => [ngon(100, 10, T), ngon(100, 5, T; ccw = false)],
            "bowtie" => [[P(0, 0), P(2, 2), P(2, 0), P(0, 2)]],
            "collinear" => [[P(0, 0), P(1, 1), P(2, 2), P(3, 3)]],
            "duplicate points" => [[P(0, 0), P(0, 0), P(1, 0), P(1, 0), P(1, 1), P(1, 1)]],
            "two points" => [[P(0, 0), P(1, 1)]],
            "empty ring" => [Point2{T}[]],
            "no rings" => Vector{Point2{T}}[],
        ]
        for (name, rings) in cases
            @test Makie.earcut_triangulate(rings) == GeometryBasics.earcut_triangulate(rings)
        end

        # random polygons, simple (star-shaped) or not (random points), with and without holes
        rng = Xoshiro(1234)
        for _ in 1:300
            n = rand(rng) < 0.2 ? rand(rng, 60:200) : rand(rng, 3:30)
            angles = [2pi * ((i - 1) + 0.8 * rand(rng)) / n for i in 1:n]
            outline = [(r = 0.3 + rand(rng); P(r * cos(a), r * sin(a))) for a in angles]
            @test Makie.earcut_triangulate([outline]) == GeometryBasics.earcut_triangulate([outline])
            garbage = [P(rand(rng, 0:4), rand(rng, 0:4)) for _ in 1:n]
            @test Makie.earcut_triangulate([garbage]) == GeometryBasics.earcut_triangulate([garbage])
            holes = [reverse(ngon(rand(rng, 3:8), 0.3, T)) .+ (P(8 * (rand(rng) - 0.5), 8 * (rand(rng) - 0.5)),) for _ in 1:rand(rng, 1:5)]
            rings = [ngon(max(n, 8), 10, T), holes...]
            @test Makie.earcut_triangulate(rings) == GeometryBasics.earcut_triangulate(rings)
        end
    end

    @testset "triangles cover the polygon" begin
        outline = star(10, Float64)
        hl = ngon(6, 0.15, Float64; ccw = false)
        faces = Makie.earcut_triangulate([outline, hl])
        @test faces isa Vector{GLTriangleFace}
        @test length(faces) == length(outline) + length(hl) + 2 * 1 - 2   # n + 2 * holes - 2
        @test area_of([outline, hl], faces) ≈ ring_area(outline) - ring_area(hl)
    end

    @testset "integer and other coordinates" begin
        rings = [[Point2{Int64}(0, 0), Point2{Int64}(10, 0), Point2{Int64}(10, 10), Point2{Int64}(0, 10)], [Point2{Int64}(4, 4), Point2{Int64}(4, 6), Point2{Int64}(6, 6), Point2{Int64}(6, 4)]]
        @test Makie.earcut_triangulate(rings) == GeometryBasics.earcut_triangulate(rings)
        # tuples and views
        pts = [Point2f(0, 0), Point2f(1, 0), Point2f(1, 1), Point2f(0, 1)]
        @test Makie.earcut_triangulate([view(pts, 1:4)]) == Makie.earcut_triangulate([pts])
        @test Makie.earcut_triangulate([Tuple.(pts)]) == Makie.earcut_triangulate([pts])
    end

    @testset "poly_convert uses it" begin
        poly = Polygon(Point2d[(0, 0), (10, 0), (10, 10), (0, 10)], [Point2d[(4, 4), (4, 6), (6, 6), (6, 4)]])
        m = Makie.poly_convert(poly)
        pts = [coordinates(poly.exterior); coordinates(poly.interiors[1])]
        @test coordinates(m) == pts
        @test GeometryBasics.faces(m) == GeometryBasics.earcut_triangulate([coordinates(poly.exterior), coordinates(poly.interiors[1])])
    end
end
