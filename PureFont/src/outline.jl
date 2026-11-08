# A glyph outline in font units, FreeType-style: a flat point list with on/off-curve tags and contour end indices.
const ON = 0x01       # on-curve point
const CONIC = 0x00    # off-curve control point of a quadratic (TrueType) segment
const CUBIC = 0x02    # off-curve control point of a cubic (CFF) segment

mutable struct Outline
    x::Vector{Float32}
    y::Vector{Float32}
    tag::Vector{UInt8}
    ends::Vector{Int32}    # 1-based index of the last point of each contour
end
Outline() = Outline(Float32[], Float32[], UInt8[], Int32[])

function Base.empty!(o::Outline)
    empty!(o.x); empty!(o.y); empty!(o.tag); empty!(o.ends)
    return o
end
npoints(o::Outline) = length(o.x)

@inline function add_point!(o::Outline, x::Real, y::Real, t::UInt8)
    push!(o.x, Float32(x)); push!(o.y, Float32(y)); push!(o.tag, t)
    return nothing
end

"Close the contour under construction (if it has points beyond the previous contour's end)."
function close_contour!(o::Outline)
    n = npoints(o)
    first = isempty(o.ends) ? 1 : Int(o.ends[end]) + 1
    n >= first || return nothing
    # (FreeType drops a last on-curve point that repeats the first)
    if n > first && o.tag[n] == ON && o.x[n] == o.x[first] && o.y[n] == o.y[first]
        pop!(o.x); pop!(o.y); pop!(o.tag); n -= 1
    end
    push!(o.ends, Int32(n))
    return nothing
end

"Control box `(xmin, ymin, xmax, ymax)` over all points, off-curve ones included, as `FT_Outline_Get_CBox`."
function cbox(o::Outline)
    n = npoints(o)
    n == 0 && return (0.0f0, 0.0f0, 0.0f0, 0.0f0)
    xmin = xmax = o.x[1]; ymin = ymax = o.y[1]
    for i in 2:n
        xmin = min(xmin, o.x[i]); xmax = max(xmax, o.x[i])
        ymin = min(ymin, o.y[i]); ymax = max(ymax, o.y[i])
    end
    return (xmin, ymin, xmax, ymax)
end
