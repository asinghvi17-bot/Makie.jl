# Makie.earcut_triangulate is a pure Julia port of earcut.hpp. It must agree with libearcut
# (GeometryBasics.earcut_triangulate), triangle for triangle, except for the order of holes with the same leftmost x
# once there are more than 16 of them (see the "holes with the same leftmost x" test).
using Random
using GeometryBasics: value

@testset "earcut" begin
    ngon(n, r, T; ccw = true) = [
        Point2{T}(r * cos((ccw ? 1 : -1) * 2pi * (i - 1) / n), r * sin((ccw ? 1 : -1) * 2pi * (i - 1) / n)) for i in 1:n
    ]
    star(n, T) = [
        Point2{T}(
                (iseven(i) ? 0.4 : 1.0) * cos(pi * (i - 1) / n),
                (iseven(i) ? 0.4 : 1.0) * sin(pi * (i - 1) / n),
            ) for i in 1:(2n)
    ]
    function area_of(rings, faces)
        pts = reduce(vcat, rings)
        tri(f) = (
            a = pts[value(f[1])]; b = pts[value(f[2])]; c = pts[value(f[3])]; abs(
                (b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2])
            ) / 2
        )
        return sum(tri, faces; init = 0.0)
    end
    ring_area(r) =
        abs(
        sum(
            i -> r[i][1] * r[mod1(i + 1, length(r))][2] - r[mod1(i + 1, length(r))][1] * r[i][2],
            eachindex(r),
        ),
    ) / 2

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
            "20 holes" => [
                [P(0, 0), P(41, 0), P(41, 10), P(0, 10)],
                [hole(1.0 + 2 * i, 1.0 + (i % 3) * 2.5) for i in 0:19]...,
            ],
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
            holes = [
                reverse(ngon(rand(rng, 3:8), 0.3, T)) .+ (P(8 * (rand(rng) - 0.5), 8 * (rand(rng) - 0.5)),)
                    for _ in 1:rand(rng, 1:5)
            ]
            rings = [ngon(max(n, 8), 10, T), holes...]
            @test Makie.earcut_triangulate(rings) == GeometryBasics.earcut_triangulate(rings)
        end
    end

    # a convex ring without holes takes a shortcut (`ec_triangulate_convex`), which has to give what the general code gives
    @testset "convex fast path ($T)" for T in (Float32, Float64)
        P(x, y) = Point2{T}(x, y)
        rng = Xoshiro(99)
        general(rings) = (
            s = Makie.EarcutState(sum(length, rings) + 2, sum(length, rings), sum(length, rings) > 80);
            outer = Makie.ec_linked_list!(s, rings[1], true);
            Makie.ec_earcut_linked!(s, outer);
            s.faces
        )
        ncovered = 0
        for _ in 1:2000
            n = rand(rng, 3:80)
            angles = sort!(2pi .* rand(rng, n))
            ring = [P(cos(a), 0.5 * sin(a)) for a in angles]
            fast = Makie.ec_triangulate_convex(ring)
            if fast !== nothing   # (nearly collinear points are not strictly convex in T)
                ncovered += 1
                @test fast == general([ring])
                @test fast == GeometryBasics.earcut_triangulate([ring])
                @test Makie.earcut_triangulate([reverse(ring)]) ==
                    GeometryBasics.earcut_triangulate([reverse(ring)])
            end
        end
        @test ncovered > 1000
        @test Makie.ec_triangulate_convex([P(0, 0), P(2, 0), P(2, 1), P(0, 1)]) ==
            GeometryBasics.earcut_triangulate([[P(0, 0), P(2, 0), P(2, 1), P(0, 1)]])
        @test Makie.ec_triangulate_convex([P(0, 0), P(0, 1), P(2, 1), P(2, 0)]) ==
            GeometryBasics.earcut_triangulate([[P(0, 0), P(0, 1), P(2, 1), P(2, 0)]])
        # not strictly convex, or not convex: the general code
        @test Makie.ec_triangulate_convex([P(0, 0), P(1, 0), P(2, 0), P(2, 1), P(0, 1)]) === nothing  # collinear
        @test Makie.ec_triangulate_convex([P(0, 0), P(1, 0), P(1, 1), P(0, 1), P(0, 0)]) === nothing  # closed
        @test Makie.ec_triangulate_convex([P(0, 0), P(2, 0), P(1, 0.5), P(2, 2), P(0, 2)]) === nothing  # reflex
        @test Makie.ec_triangulate_convex([P(cos(2pi * 2i / 5), sin(2pi * 2i / 5)) for i in 0:4]) === nothing  # pentagram
        @test Makie.ec_triangulate_convex([P(0, 0), P(1, 0)]) === nothing
        @test Makie.ec_triangulate_convex(ngon(81, 1, T)) === nothing  # (z-order hashing for these)
    end

    # The order of the holes of a polygon is that of a sort by their leftmost x. `std::sort` of libstdc++ (which libearcut
    # uses) is an insertion sort up to 16 holes, and the port uses a stable sort, so these agree. For more holes with
    # the same leftmost x libstdc++'s introsort is free to order them differently (and does): the triangles are then
    # not the same as libearcut's, but still a triangulation of the polygon, which is what is checked here.
    @testset "holes with the same leftmost x" begin
        P(x, y) = Point2{Float64}(x, y)
        tri_area(a, b, c) = ((b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2])) / 2
        # whether the interiors of two triangles overlap (separating axis test, touching is fine)
        function overlap(t, u)
            for tri in (t, u), i in 1:3
                a, b = tri[i], tri[mod1(i + 1, 3)]
                nrm = (a[2] - b[2], b[1] - a[1])
                pt = [nrm[1] * v[1] + nrm[2] * v[2] for v in t]
                pu = [nrm[1] * v[1] + nrm[2] * v[2] for v in u]
                (maximum(pt) <= minimum(pu) + 1.0e-9 || maximum(pu) <= minimum(pt) + 1.0e-9) && return false
            end
            return true
        end
        @test overlap((P(0, 0), P(2, 0), P(0, 2)), (P(0.5, 0.5), P(3, 0.5), P(0.5, 3)))
        @test !overlap((P(0, 0), P(2, 0), P(0, 2)), (P(2, 0), P(2, 2), P(0, 2))) # sharing an edge
        @testset "$nh holes" for nh in (3, 16, 17, 20, 40)
            outer = [P(0, 0), P(10, 0), P(10, 6nh), P(0, 6nh)]
            holes = [reverse([P(2, 6i - 4), P(5, 6i - 4), P(5, 6i - 1), P(2, 6i - 1)]) for i in 1:nh] # all with leftmost x = 2
            for rings in
                (Vector{Point2{Float64}}[outer, holes...], Vector{Point2{Float64}}[outer, reverse(holes)...])
                faces = Makie.earcut_triangulate(rings)
                pts = reduce(vcat, rings)
                tris = [(pts[value(f[1])], pts[value(f[2])], pts[value(f[3])]) for f in faces]
                @test length(faces) == length(pts) + 2 * nh - 2
                # every input vertex is used
                @test Set(value(i) for f in faces for i in f) == Set(1:length(pts))
                # the triangles cover the polygon without overlapping
                @test sum(t -> abs(tri_area(t...)), tris) ≈ 10 * 6nh - nh * 3 * 3
                @test !any(overlap(tris[i], tris[j]) for i in eachindex(tris) for j in (i + 1):length(tris))
                # no triangle has a hole's center inside
                @test all(
                    i ->
                    !any(
                        t ->
                        all(
                            e -> tri_area(e..., P(3.5, 6i - 2.5)) > 0,
                            ((t[1], t[2]), (t[2], t[3]), (t[3], t[1])),
                        ) || all(
                            e -> tri_area(e..., P(3.5, 6i - 2.5)) < 0,
                            ((t[1], t[2]), (t[2], t[3]), (t[3], t[1])),
                        ),
                        tris,
                    ),
                    1:nh,
                )
                # up to 16 holes the order is libearcut's
                nh <= 16 && @test faces == GeometryBasics.earcut_triangulate(rings)
            end
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
        rings = [
            [Point2{Int64}(0, 0), Point2{Int64}(10, 0), Point2{Int64}(10, 10), Point2{Int64}(0, 10)],
            [Point2{Int64}(4, 4), Point2{Int64}(4, 6), Point2{Int64}(6, 6), Point2{Int64}(6, 4)],
        ]
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
        @test GeometryBasics.faces(m) ==
            GeometryBasics.earcut_triangulate([coordinates(poly.exterior), coordinates(poly.interiors[1])])
    end
end
