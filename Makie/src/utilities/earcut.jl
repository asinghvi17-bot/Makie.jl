# A pure Julia port of mapbox's earcut polygon triangulation, following earcut.hpp v2.2.4
# (https://github.com/mapbox/earcut.hpp, the C++ port of https://github.com/mapbox/earcut), which is what
# `libearcut` (EarCut_jll, called by `GeometryBasics.earcut_triangulate`) is built from. The triangles come out
# in the same order, with the same vertex order, as `libearcut`'s (tested on a corpus of random, degenerate and
# recipe-shaped polygons, see test/isolated/earcut.jl), except for the order of holes that have the same leftmost x
# when there are more than 16 of them: earcut sorts the holes by that x, and `std::sort` (libstdc++, an introsort for
# more than 16 elements) may put equal ones in another order than the stable sort here. The result is then another
# triangulation of the same polygon. It is plain Julia so that it compiles ahead of time (e.g. to Wasm) where the
# `ccall` into `libearcut` cannot, and it is also faster than that `ccall` from Julia (see the changelog).
#
# Besides that, ring-only polygons that are strictly convex (the rectangles of `barplot` and `hist`) take a shortcut,
# `ec_triangulate_convex`, which clips the ears like the general code does but without building the linked lists.
#
# Copyright (c) 2015, Mapbox
#
# Permission to use, copy, modify, and/or distribute this software for any purpose
# with or without fee is hereby granted, provided that the above copyright notice
# and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
# OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
# TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
# THIS SOFTWARE.

# The nodes of earcut's circular doubly linked lists live in parallel vectors, a node being an `Int` index into
# them (`0` is the null node). That keeps every field concretely typed (no `Union{Nothing, Node}` links).
# All arithmetic is done in `Float64`, as in earcut.hpp, whatever the element type of the input is.
mutable struct EarcutState
    x::Vector{Float64}
    y::Vector{Float64}
    id::Vector{Int}           # 0-based index of the input vertex a node belongs to
    prev::Vector{Int}
    next::Vector{Int}
    z::Vector{Int32}          # z-order curve value
    prevz::Vector{Int}        # previous and next nodes in z-order
    nextz::Vector{Int}
    steiner::Vector{Bool}
    faces::Vector{GLTriangleFace}  # the output
    vertices::Int             # number of input vertices linked so far
    hashing::Bool
    minx::Float64
    miny::Float64
    inv_size::Float64
end

# `nodes` is the number of nodes expected, `ntriangles` the number of triangles. The vectors are allocated for them once,
# so that building the lists does not reallocate. The z-order fields are only needed (and only allocated) when hashing.
function EarcutState(nodes::Int, ntriangles::Int, hashing::Bool)
    alloc(::Type{T}) where {T} = sizehint!(T[], nodes)
    zs = hashing ? nodes : 0
    faces = sizehint!(GLTriangleFace[], ntriangles)
    return EarcutState(
        alloc(Float64),
        alloc(Float64),
        alloc(Int),
        alloc(Int),
        alloc(Int),
        sizehint!(Int32[], zs),
        sizehint!(Int[], zs),
        sizehint!(Int[], zs),
        alloc(Bool),
        faces,
        0,
        hashing,
        0.0,
        0.0,
        0.0,
    )
end

# create a node and optionally link it with the previous one (in a circular doubly linked list)
function ec_insert_node!(s::EarcutState, i::Int, x::Float64, y::Float64, last::Int)::Int
    p = ec_new_node!(s, i, x, y)
    if last == 0
        s.prev[p] = p
        s.next[p] = p
    else
        n = s.next[last]
        s.next[p] = n
        s.prev[p] = last
        s.prev[n] = p
        s.next[last] = p
    end
    return p
end

function ec_new_node!(s::EarcutState, i::Int, x::Float64, y::Float64)::Int
    push!(s.x, x)
    push!(s.y, y)
    push!(s.id, i)
    push!(s.prev, 0)
    push!(s.next, 0)
    if s.hashing
        push!(s.z, Int32(0))
        push!(s.prevz, 0)
        push!(s.nextz, 0)
    end
    push!(s.steiner, false)
    return length(s.x)
end

function ec_remove_node!(s::EarcutState, p::Int)::Nothing
    s.next[s.prev[p]] = s.next[p]
    s.prev[s.next[p]] = s.prev[p]
    if s.hashing
        s.prevz[p] != 0 && (s.nextz[s.prevz[p]] = s.nextz[p])
        s.nextz[p] != 0 && (s.prevz[s.nextz[p]] = s.prevz[p])
    end
    return nothing
end

# create a circular doubly linked list from polygon points in the specified winding order
function ec_linked_list!(s::EarcutState, points, clockwise::Bool)::Int
    len = length(points)
    last = 0
    sm = 0.0

    # calculate original winding order of a polygon ring
    j = len > 0 ? len : 1
    for i in 1:len
        p1 = points[i]
        p2 = points[j]
        sm += (Float64(p2[1]) - Float64(p1[1])) * (Float64(p1[2]) + Float64(p2[2]))
        j = i
    end

    # link points into circular doubly-linked list in the specified winding order
    if clockwise == (sm > 0)
        for i in 1:len
            p = points[i]
            last = ec_insert_node!(s, s.vertices + i - 1, Float64(p[1]), Float64(p[2]), last)
        end
    else
        for i in len:-1:1
            p = points[i]
            last = ec_insert_node!(s, s.vertices + i - 1, Float64(p[1]), Float64(p[2]), last)
        end
    end

    if last != 0 && ec_equals(s, last, s.next[last])
        ec_remove_node!(s, last)
        last = s.next[last]
    end

    s.vertices += len
    return last
end

# eliminate colinear or duplicate points
function ec_filter_points!(s::EarcutState, start::Int, stop::Int = 0)::Int
    stop == 0 && (stop = start)
    p = start
    while true
        again = false
        if !s.steiner[p] && (ec_equals(s, p, s.next[p]) || ec_area(s, s.prev[p], p, s.next[p]) == 0)
            ec_remove_node!(s, p)
            p = stop = s.prev[p]
            p == s.next[p] && break
            again = true
        else
            p = s.next[p]
        end
        (again || p != stop) || break
    end
    return stop
end

# main ear slicing loop which triangulates a polygon (given as a linked list)
function ec_earcut_linked!(s::EarcutState, ear::Int, pass::Int = 0)::Nothing
    ear == 0 && return nothing

    # interlink polygon nodes in z-order
    pass == 0 && s.hashing && ec_index_curve!(s, ear)

    stop = ear

    # iterate through ears, slicing them one by one
    while s.prev[ear] != s.next[ear]
        prev = s.prev[ear]
        next = s.next[ear]

        if s.hashing ? ec_is_ear_hashed(s, ear) : ec_is_ear(s, ear)
            # cut off the triangle
            push!(s.faces, GLTriangleFace(s.id[prev] + 1, s.id[ear] + 1, s.id[next] + 1))

            ec_remove_node!(s, ear)

            # skipping the next vertex leads to less sliver triangles
            ear = s.next[next]
            stop = s.next[next]
            continue
        end

        ear = next

        # if we looped through the whole remaining polygon and can't find any more ears
        if ear == stop
            if pass == 0
                # try filtering points and slicing again
                ec_earcut_linked!(s, ec_filter_points!(s, ear), 1)
            elseif pass == 1
                # if this didn't work, try curing all small self-intersections locally
                ear = ec_cure_local_intersections!(s, ec_filter_points!(s, ear))
                ec_earcut_linked!(s, ear, 2)
            elseif pass == 2
                # as a last resort, try splitting the remaining polygon into two
                ec_split_earcut!(s, ear)
            end
            break
        end
    end
    return nothing
end

# check whether a polygon node forms a valid ear with adjacent nodes
function ec_is_ear(s::EarcutState, ear::Int)::Bool
    a = s.prev[ear]
    b = ear
    c = s.next[ear]

    ec_area(s, a, b, c) >= 0 && return false # reflex, can't be an ear

    # now make sure we don't have other points inside the potential ear
    p = s.next[s.next[ear]]
    while p != s.prev[ear]
        if ec_point_in_triangle(s.x[a], s.y[a], s.x[b], s.y[b], s.x[c], s.y[c], s.x[p], s.y[p]) &&
                ec_area(s, s.prev[p], p, s.next[p]) >= 0
            return false
        end
        p = s.next[p]
    end
    return true
end

function ec_is_ear_hashed(s::EarcutState, ear::Int)::Bool
    a = s.prev[ear]
    b = ear
    c = s.next[ear]

    ec_area(s, a, b, c) >= 0 && return false # reflex, can't be an ear

    # triangle bbox
    min_tx = min(s.x[a], min(s.x[b], s.x[c]))
    min_ty = min(s.y[a], min(s.y[b], s.y[c]))
    max_tx = max(s.x[a], max(s.x[b], s.x[c]))
    max_ty = max(s.y[a], max(s.y[b], s.y[c]))

    # z-order range for the current triangle bbox
    min_z = ec_z_order(s, min_tx, min_ty)
    max_z = ec_z_order(s, max_tx, max_ty)

    # first look for points inside the triangle in increasing z-order
    p = s.nextz[ear]
    while p != 0 && s.z[p] <= max_z
        if p != s.prev[ear] &&
                p != s.next[ear] &&
                ec_point_in_triangle(s.x[a], s.y[a], s.x[b], s.y[b], s.x[c], s.y[c], s.x[p], s.y[p]) &&
                ec_area(s, s.prev[p], p, s.next[p]) >= 0
            return false
        end
        p = s.nextz[p]
    end

    # then look for points in decreasing z-order
    p = s.prevz[ear]
    while p != 0 && s.z[p] >= min_z
        if p != s.prev[ear] &&
                p != s.next[ear] &&
                ec_point_in_triangle(s.x[a], s.y[a], s.x[b], s.y[b], s.x[c], s.y[c], s.x[p], s.y[p]) &&
                ec_area(s, s.prev[p], p, s.next[p]) >= 0
            return false
        end
        p = s.prevz[p]
    end
    return true
end

# go through all polygon nodes and cure small local self-intersections
function ec_cure_local_intersections!(s::EarcutState, start::Int)::Int
    p = start
    while true
        a = s.prev[p]
        b = s.next[s.next[p]]

        # a self-intersection where edge (v[i-1],v[i]) intersects (v[i+1],v[i+2])
        if !ec_equals(s, a, b) &&
                ec_intersects(s, a, p, s.next[p], b) &&
                ec_locally_inside(s, a, b) &&
                ec_locally_inside(s, b, a)
            push!(s.faces, GLTriangleFace(s.id[a] + 1, s.id[p] + 1, s.id[b] + 1))

            # remove two nodes involved
            ec_remove_node!(s, p)
            ec_remove_node!(s, s.next[p])

            p = start = b
        end
        p = s.next[p]
        p != start || break
    end
    return ec_filter_points!(s, p)
end

# try splitting polygon into two and triangulate them independently
function ec_split_earcut!(s::EarcutState, start::Int)::Nothing
    # look for a valid diagonal that divides the polygon into two
    a = start
    while true
        b = s.next[s.next[a]]
        while b != s.prev[a]
            if s.id[a] != s.id[b] && ec_is_valid_diagonal(s, a, b)
                # split the polygon in two by the diagonal
                c = ec_split_polygon!(s, a, b)

                # filter colinear points around the cuts
                a = ec_filter_points!(s, a, s.next[a])
                c = ec_filter_points!(s, c, s.next[c])

                # run earcut on each half
                ec_earcut_linked!(s, a)
                ec_earcut_linked!(s, c)
                return nothing
            end
            b = s.next[b]
        end
        a = s.next[a]
        a != start || break
    end
    return nothing
end

# link every hole into the outer loop, producing a single-ring polygon without holes
function ec_eliminate_holes!(s::EarcutState, rings, outer::Int)::Int
    queue = sizehint!(Int[], length(rings) - 1)
    for i in 2:length(rings)
        list = ec_linked_list!(s, rings[i], false)
        if list != 0
            list == s.next[list] && (s.steiner[list] = true)
            push!(queue, ec_get_leftmost(s, list))
        end
    end

    # By x only: the order of holes with the same leftmost x is that of a stable sort (the same as `std::sort`
    # of libstdc++ for up to 16 holes, which is an insertion sort there; its introsort may order ties differently).
    sort!(queue; by = i -> s.x[i], alg = Base.Sort.MergeSort)

    # process holes from left to right
    for hole in queue
        outer = ec_eliminate_hole!(s, hole, outer)
    end
    return outer
end

# find a bridge between vertices that connects hole with an outer ring and link it
function ec_eliminate_hole!(s::EarcutState, hole::Int, outer::Int)::Int
    bridge = ec_find_hole_bridge(s, hole, outer)
    bridge == 0 && return outer

    bridge_reverse = ec_split_polygon!(s, bridge, hole)

    # filter collinear points around the cuts
    ec_filter_points!(s, bridge_reverse, s.next[bridge_reverse])

    # check if the input node was removed by the filtering
    return ec_filter_points!(s, bridge, s.next[bridge])
end

# David Eberly's algorithm for finding a bridge between hole and outer polygon
function ec_find_hole_bridge(s::EarcutState, hole::Int, outer::Int)::Int
    p = outer
    hx = s.x[hole]
    hy = s.y[hole]
    qx = -Inf
    m = 0

    # find a segment intersected by a ray from the hole's leftmost point to the left;
    # segment's endpoint with lesser x will be potential connection point
    while true
        pn = s.next[p]
        if hy <= s.y[p] && hy >= s.y[pn] && s.y[pn] != s.y[p]
            x = s.x[p] + (hy - s.y[p]) * (s.x[pn] - s.x[p]) / (s.y[pn] - s.y[p])
            if x <= hx && x > qx
                qx = x
                m = s.x[p] < s.x[pn] ? p : pn
                x == hx && return m # hole touches outer segment; pick leftmost endpoint
            end
        end
        p = pn
        p != outer || break
    end

    m == 0 && return 0

    # look for points inside the triangle of hole point, segment intersection and endpoint;
    # if there are no points found, we have a valid connection;
    # otherwise choose the point of the minimum angle with the ray as connection point
    stop = m
    tan_min = Inf
    p = m
    mx = s.x[m]
    my = s.y[m]

    while true
        if hx >= s.x[p] &&
                s.x[p] >= mx &&
                hx != s.x[p] &&
                ec_point_in_triangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, s.x[p], s.y[p])
            tan_cur = abs(hy - s.y[p]) / (hx - s.x[p]) # tangential

            if ec_locally_inside(s, p, hole) && (
                    tan_cur < tan_min ||
                        (tan_cur == tan_min && (s.x[p] > s.x[m] || ec_sector_contains_sector(s, m, p)))
                )
                m = p
                tan_min = tan_cur
            end
        end
        p = s.next[p]
        p != stop || break
    end
    return m
end

# whether sector in vertex m contains sector in vertex p in the same coordinates
function ec_sector_contains_sector(s::EarcutState, m::Int, p::Int)::Bool
    return ec_area(s, s.prev[m], m, s.prev[p]) < 0 && ec_area(s, s.next[p], m, s.next[m]) < 0
end

# interlink polygon nodes in z-order
function ec_index_curve!(s::EarcutState, start::Int)::Nothing
    p = start
    while true
        s.z[p] = s.z[p] != 0 ? s.z[p] : ec_z_order(s, s.x[p], s.y[p])
        s.prevz[p] = s.prev[p]
        s.nextz[p] = s.next[p]
        p = s.next[p]
        p != start || break
    end

    s.nextz[s.prevz[p]] = 0
    s.prevz[p] = 0

    ec_sort_linked!(s, p)
    return nothing
end

# Simon Tatham's linked list merge sort algorithm
# http://www.chiark.greenend.org.uk/~sgtatham/algorithms/listsort.html
function ec_sort_linked!(s::EarcutState, list::Int)::Int
    insize = 1
    while true
        p = list
        list = 0
        tail = 0
        nmerges = 0

        while p != 0
            nmerges += 1
            q = p
            psize = 0
            for _ in 1:insize
                psize += 1
                q = s.nextz[q]
                q == 0 && break
            end

            qsize = insize

            while psize > 0 || (qsize > 0 && q != 0)
                if psize == 0
                    e = q
                    q = s.nextz[q]
                    qsize -= 1
                elseif qsize == 0 || q == 0
                    e = p
                    p = s.nextz[p]
                    psize -= 1
                elseif s.z[p] <= s.z[q]
                    e = p
                    p = s.nextz[p]
                    psize -= 1
                else
                    e = q
                    q = s.nextz[q]
                    qsize -= 1
                end

                if tail != 0
                    s.nextz[tail] = e
                else
                    list = e
                end

                s.prevz[e] = tail
                tail = e
            end

            p = q
        end

        s.nextz[tail] = 0

        nmerges <= 1 && return list

        insize *= 2
    end
    return nothing
end

# z-order of a point given coords and size of the data bounding box
function ec_z_order(s::EarcutState, x_::Float64, y_::Float64)::Int32
    # coords are transformed into non-negative 15-bit integer range
    x = unsafe_trunc(Int32, (x_ - s.minx) * s.inv_size)
    y = unsafe_trunc(Int32, (y_ - s.miny) * s.inv_size)

    x = (x | (x << 8)) & Int32(0x00FF00FF)
    x = (x | (x << 4)) & Int32(0x0F0F0F0F)
    x = (x | (x << 2)) & Int32(0x33333333)
    x = (x | (x << 1)) & Int32(0x55555555)

    y = (y | (y << 8)) & Int32(0x00FF00FF)
    y = (y | (y << 4)) & Int32(0x0F0F0F0F)
    y = (y | (y << 2)) & Int32(0x33333333)
    y = (y | (y << 1)) & Int32(0x55555555)

    return x | (y << 1)
end

# find the leftmost node of a polygon ring
function ec_get_leftmost(s::EarcutState, start::Int)::Int
    p = start
    leftmost = start
    while true
        if s.x[p] < s.x[leftmost] || (s.x[p] == s.x[leftmost] && s.y[p] < s.y[leftmost])
            leftmost = p
        end
        p = s.next[p]
        p != start || break
    end
    return leftmost
end

# check if a point lies within a convex triangle
function ec_point_in_triangle(
        ax::Float64, ay::Float64, bx::Float64, by::Float64, cx::Float64, cy::Float64, px::Float64, py::Float64
    )::Bool
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
        (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
        (bx - px) * (cy - py) >= (cx - px) * (by - py)
end

# check if a diagonal between two polygon nodes is valid (lies in polygon interior)
function ec_is_valid_diagonal(s::EarcutState, a::Int, b::Int)::Bool
    return s.id[s.next[a]] != s.id[b] &&
        s.id[s.prev[a]] != s.id[b] &&
        !ec_intersects_polygon(s, a, b) && # doesn't intersect other edges
        (
        (
            ec_locally_inside(s, a, b) &&
                ec_locally_inside(s, b, a) &&
                ec_middle_inside(s, a, b) && # locally visible
                (ec_area(s, s.prev[a], a, s.prev[b]) != 0.0 || ec_area(s, a, s.prev[b], b) != 0.0) # does not create opposite-facing sectors
        ) || (
            ec_equals(s, a, b) &&
                ec_area(s, s.prev[a], a, s.next[a]) > 0 &&
                ec_area(s, s.prev[b], b, s.next[b]) > 0
        )
    ) # special zero-length case
end

# signed area of a triangle
function ec_area(s::EarcutState, p::Int, q::Int, r::Int)::Float64
    return (s.y[q] - s.y[p]) * (s.x[r] - s.x[q]) - (s.x[q] - s.x[p]) * (s.y[r] - s.y[q])
end

# check if two points are equal
ec_equals(s::EarcutState, p1::Int, p2::Int)::Bool = s.x[p1] == s.x[p2] && s.y[p1] == s.y[p2]

# check if two segments intersect
function ec_intersects(s::EarcutState, p1::Int, q1::Int, p2::Int, q2::Int)::Bool
    o1 = ec_sign(ec_area(s, p1, q1, p2))
    o2 = ec_sign(ec_area(s, p1, q1, q2))
    o3 = ec_sign(ec_area(s, p2, q2, p1))
    o4 = ec_sign(ec_area(s, p2, q2, q1))

    o1 != o2 && o3 != o4 && return true # general case

    o1 == 0 && ec_on_segment(s, p1, p2, q1) && return true # p1, q1 and p2 are collinear and p2 lies on p1q1
    o2 == 0 && ec_on_segment(s, p1, q2, q1) && return true # p1, q1 and q2 are collinear and q2 lies on p1q1
    o3 == 0 && ec_on_segment(s, p2, p1, q2) && return true # p2, q2 and p1 are collinear and p1 lies on p2q2
    o4 == 0 && ec_on_segment(s, p2, q1, q2) && return true # p2, q2 and q1 are collinear and q1 lies on p2q2

    return false
end

# for collinear points p, q, r, check if point q lies on segment pr
function ec_on_segment(s::EarcutState, p::Int, q::Int, r::Int)::Bool
    return s.x[q] <= max(s.x[p], s.x[r]) &&
        s.x[q] >= min(s.x[p], s.x[r]) &&
        s.y[q] <= max(s.y[p], s.y[r]) &&
        s.y[q] >= min(s.y[p], s.y[r])
end

ec_sign(val::Float64)::Int = Int(0.0 < val) - Int(val < 0.0)

# check if a polygon diagonal intersects any polygon segments
function ec_intersects_polygon(s::EarcutState, a::Int, b::Int)::Bool
    p = a
    while true
        pn = s.next[p]
        if s.id[p] != s.id[a] &&
                s.id[pn] != s.id[a] &&
                s.id[p] != s.id[b] &&
                s.id[pn] != s.id[b] &&
                ec_intersects(s, p, pn, a, b)
            return true
        end
        p = pn
        p != a || break
    end
    return false
end

# check if a polygon diagonal is locally inside the polygon
function ec_locally_inside(s::EarcutState, a::Int, b::Int)::Bool
    return if ec_area(s, s.prev[a], a, s.next[a]) < 0
        ec_area(s, a, b, s.next[a]) >= 0 && ec_area(s, a, s.prev[a], b) >= 0
    else
        ec_area(s, a, b, s.prev[a]) < 0 || ec_area(s, a, s.next[a], b) < 0
    end
end

# check if the middle point of a polygon diagonal is inside the polygon
function ec_middle_inside(s::EarcutState, a::Int, b::Int)::Bool
    p = a
    inside = false
    px = (s.x[a] + s.x[b]) / 2
    py = (s.y[a] + s.y[b]) / 2
    while true
        pn = s.next[p]
        if ((s.y[p] > py) != (s.y[pn] > py)) &&
                s.y[pn] != s.y[p] &&
                (px < (s.x[pn] - s.x[p]) * (py - s.y[p]) / (s.y[pn] - s.y[p]) + s.x[p])
            inside = !inside
        end
        p = pn
        p != a || break
    end
    return inside
end

# link two polygon vertices with a bridge; if the vertices belong to the same ring, it splits
# the polygon into two; if one belongs to the outer ring and another to a hole, it merges it
# into a single ring
function ec_split_polygon!(s::EarcutState, a::Int, b::Int)::Int
    a2 = ec_new_node!(s, s.id[a], s.x[a], s.y[a])
    b2 = ec_new_node!(s, s.id[b], s.x[b], s.y[b])
    an = s.next[a]
    bp = s.prev[b]

    s.next[a] = b
    s.prev[b] = a

    s.next[a2] = an
    s.prev[an] = a2

    s.next[b2] = a2
    s.prev[a2] = b2

    s.next[bp] = b2
    s.prev[b2] = bp

    return b2
end

# The fast path for convex rings without holes (rectangles of a `barplot`, wedges of a `pie`, ...). In such a ring every
# vertex is an ear and none of the others can lie inside the triangle of an ear, so the ear test of `ec_earcut_linked!`
# is just the sign of the area. This does the same clipping as `ec_earcut_linked!` (same triangles in the same order)
# on two small index vectors, without building the state. Returns `nothing` if the ring is not strictly convex (or
# anything is off with the arithmetic), when the general code has to do it.
function ec_triangulate_convex(ring)::Union{Nothing, Vector{GLTriangleFace}}
    n = length(ring)
    (3 <= n <= 80) || return nothing
    X(i) = Float64(ring[i][1])
    Y(i) = Float64(ring[i][2])

    # winding order of the ring, as in `ec_linked_list!` (which links the ring clockwise)
    sm = 0.0
    j = n
    for i in 1:n
        sm += (X(j) - X(i)) * (Y(i) + Y(j))
        j = i
    end
    fwd = sm > 0
    # position `k` of the linked list is the vertex `idx(k)` of the ring
    idx(k) = fwd ? k : n - k + 1
    nxt(k) = k == n ? 1 : k + 1
    prv(k) = k == 1 ? n : k - 1
    px(k) = X(idx(k))
    py(k) = Y(idx(k))
    area(a, b, c) = (py(b) - py(a)) * (px(c) - px(b)) - (px(b) - px(a)) * (py(c) - py(b))

    # strictly convex: all turns the same way, and the edge directions change sign at most twice in x and in y
    # (otherwise the ring winds around more than once, like a pentagram, and has points inside its ears)
    xchanges = ychanges = 0
    firstdx = lastdx = firstdy = lastdy = 0
    for k in 1:n
        area(prv(k), k, nxt(k)) < 0 || return nothing
        dx = Int(sign(px(nxt(k)) - px(k)))
        dy = Int(sign(py(nxt(k)) - py(k)))
        if dx != 0
            firstdx == 0 && (firstdx = dx)
            xchanges += lastdx != 0 && dx != lastdx
            lastdx = dx
        end
        if dy != 0
            firstdy == 0 && (firstdy = dy)
            ychanges += lastdy != 0 && dy != lastdy
            lastdy = dy
        end
    end
    xchanges += firstdx != lastdx # the edge from the last to the first position closes the cycle
    ychanges += firstdy != lastdy
    (xchanges <= 2 && ychanges <= 2) || return nothing

    # clip the ears, starting from the last position, as `ec_earcut_linked!` does
    faces = Vector{GLTriangleFace}(undef, n - 2)
    links = Vector{Int}(undef, 2 * n) # prev of k at 2k - 1, next at 2k
    for k in 1:n
        links[2k - 1] = prv(k)
        links[2k] = nxt(k)
    end
    ear = n
    for t in 1:(n - 2)
        a = links[2ear - 1]
        c = links[2ear]
        area(a, ear, c) < 0 || return nothing
        faces[t] = GLTriangleFace(idx(a), idx(ear), idx(c))
        links[2a] = c # remove the ear
        links[2c - 1] = a
        ear = links[2c] # skipping the next vertex leads to less sliver triangles
    end
    return faces
end

"""
    earcut_triangulate(rings)::Vector{GLTriangleFace}

Triangulate the polygon with outer ring `rings[1]` and holes `rings[2:end]`, each a vector of 2D points,
using a pure Julia port of mapbox's earcut. The faces index into the concatenation of all `rings`, and are the
same faces in the same order as `GeometryBasics.earcut_triangulate(rings)`, which calls `libearcut`, with one exception:
holes are linked into the outer ring from left to right, and the order of holes with the same leftmost x is that of a
stable sort. That is also the order of `libearcut`'s `std::sort` up to 16 holes, but not necessarily with more, where the
triangles may then differ from libearcut's (they are still a valid triangulation of the polygon).
"""
function earcut_triangulate(rings::AbstractVector{<:AbstractVector{<:VecTypes{2}}})::Vector{GLTriangleFace}
    isempty(rings) && return GLTriangleFace[]

    if length(rings) == 1
        faces = ec_triangulate_convex(rings[1])
        faces === nothing || return faces
    end

    npoints = 0
    for ring in rings
        npoints += length(ring)
    end
    # the z-order curve hash is used when the shape is not too simple
    hashing = npoints > 80
    # a node for each point, two more for each hole (its bridge to the outer ring), and a triangle for each point
    # (plus two for each hole) of the polygon
    nholes = length(rings) - 1
    s = EarcutState(npoints + 2 * nholes + 2, max(npoints + 2 * nholes - 2, 0), hashing)

    outer = ec_linked_list!(s, rings[1], true)
    (outer == 0 || s.prev[outer] == s.next[outer]) && return s.faces

    nholes > 0 && (outer = ec_eliminate_holes!(s, rings, outer))

    if s.hashing
        # calculate the polygon bbox
        p = s.next[outer]
        minx = maxx = s.x[outer]
        miny = maxy = s.y[outer]
        while true
            minx = min(minx, s.x[p])
            miny = min(miny, s.y[p])
            maxx = max(maxx, s.x[p])
            maxy = max(maxy, s.y[p])
            p = s.next[p]
            p != outer || break
        end

        # minx, miny and inv_size are later used to transform coords into integers for z-order calculation
        inv_size = max(maxx - minx, maxy - miny)
        s.minx = minx
        s.miny = miny
        s.inv_size = inv_size != 0.0 ? 32767.0 / inv_size : 0.0
    end

    ec_earcut_linked!(s, outer)
    return s.faces
end
