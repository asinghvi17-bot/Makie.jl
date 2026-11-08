# Anti-aliased scanline rasterizer: exact signed-area coverage accumulation (the scheme of FreeType's smooth
# rasterizer and of font-rs), with the non-zero winding rule applied to the accumulated coverage.

# FreeType's 16.16 fixed-point helpers, so scaled coordinates (26.6) round exactly as FreeType rounds them.
@inline fixed_divfix(a::Int, b::Int) = ((a << 16) + (b >> 1)) ÷ b
@inline function fixed_mulfix(a::Int, b::Int)
    s = (a < 0) != (b < 0) ? -1 : 1
    return s * ((abs(a) * abs(b) + 0x8000) >> 16)
end

"A coverage accumulation buffer for a `w` x `h` bitmap."
mutable struct Accum
    w::Int
    h::Int
    a::Vector{Float32}          # (w + 2) per row: lines may touch one cell past the right edge
end
Accum(w::Int, h::Int) = Accum(w, h, zeros(Float32, (w + 2) * h + 2))

function accum_line!(acc::Accum, x0::Float32, y0::Float32, x1::Float32, y1::Float32)
    y0 == y1 && return nothing
    dir = 1.0f0
    if y0 > y1
        x0, y0, x1, y1 = x1, y1, x0, y0
        dir = -1.0f0
    end
    dxdy = (x1 - x0) / (y1 - y0)
    x = x0
    ystart = 0
    if y0 < 0
        x -= y0 * dxdy
    else
        ystart = floor(Int, y0)
    end
    stride = acc.w + 2
    yend = min(acc.h, ceil(Int, y1))
    for y in ystart:yend - 1
        row = y * stride
        dy = min(Float32(y + 1), y1) - max(Float32(y), y0)
        xnext = x + dxdy * dy
        d = dy * dir
        xa, xb = x < xnext ? (x, xnext) : (xnext, x)
        xa = clamp(xa, 0.0f0, Float32(acc.w)); xb = clamp(xb, 0.0f0, Float32(acc.w))
        x0floor = floor(xa)
        x0i = Int(x0floor)
        x1ceil = ceil(xb)
        x1i = Int(x1ceil)
        if x1i <= x0i + 1
            xmf = 0.5f0 * (xa + xb) - x0floor
            acc.a[row + x0i + 1] += d - d * xmf
            acc.a[row + x0i + 2] += d * xmf
        else
            s = 1.0f0 / (xb - xa)
            x0f = xa - x0floor
            a0 = 0.5f0 * s * (1.0f0 - x0f) * (1.0f0 - x0f)
            x1f = xb - x1ceil + 1.0f0
            am = 0.5f0 * s * x1f * x1f
            acc.a[row + x0i + 1] += d * a0
            if x1i == x0i + 2
                acc.a[row + x0i + 2] += d * (1.0f0 - a0 - am)
            else
                a1 = s * (1.5f0 - x0f)
                acc.a[row + x0i + 2] += d * (a1 - a0)
                for xi in x0i + 2:x1i - 2
                    acc.a[row + xi + 1] += d * s
                end
                a2 = a1 + Float32(x1i - x0i - 3) * s
                acc.a[row + x1i] += d * (1.0f0 - a2 - am)
            end
            acc.a[row + x1i + 1] += d * am
        end
        x = xnext
    end
    return nothing
end

function accum_quad!(acc::Accum, x0, y0, x1, y1, x2, y2)
    dd = abs(x0 - 2x1 + x2) + abs(y0 - 2y1 + y2)
    n = clamp(ceil(Int, sqrt(dd / 0.08f0)), 1, 64)
    px = x0; py = y0
    for i in 1:n
        t = Float32(i) / n; u = 1 - t
        qx = u * u * x0 + 2u * t * x1 + t * t * x2
        qy = u * u * y0 + 2u * t * y1 + t * t * y2
        accum_line!(acc, px, py, qx, qy)
        px = qx; py = qy
    end
    return nothing
end

function accum_cubic!(acc::Accum, x0, y0, x1, y1, x2, y2, x3, y3)
    dd = max(abs(x0 - 2x1 + x2) + abs(y0 - 2y1 + y2), abs(x1 - 2x2 + x3) + abs(y1 - 2y2 + y3))
    n = clamp(ceil(Int, sqrt(dd * 0.75f0 / 0.04f0)), 1, 64)
    px = x0; py = y0
    for i in 1:n
        t = Float32(i) / n; u = 1 - t
        b0 = u * u * u; b1 = 3u * u * t; b2 = 3u * t * t; b3 = t * t * t
        qx = b0 * x0 + b1 * x1 + b2 * x2 + b3 * x3
        qy = b0 * y0 + b1 * y1 + b2 * y2 + b3 * y3
        accum_line!(acc, px, py, qx, qy)
        px = qx; py = qy
    end
    return nothing
end

"Draw the contour made of points `i0:i1` of the (pixel-space) arrays; `CONIC`, `CUBIC` and `ON` tags as FreeType."
function accum_contour!(acc::Accum, xs::Vector{Float32}, ys::Vector{Float32}, tg::Vector{UInt8}, i0::Int, i1::Int)
    i1 > i0 || return nothing
    local sx::Float32, sy::Float32
    first = i0; last = i1
    if tg[i0] == ON
        sx = xs[i0]; sy = ys[i0]; first = i0 + 1
    elseif tg[i1] == ON
        sx = xs[i1]; sy = ys[i1]; last = i1 - 1
    else
        sx = 0.5f0 * (xs[i0] + xs[i1]); sy = 0.5f0 * (ys[i0] + ys[i1])
    end
    cx = sx; cy = sy
    j = first
    while j <= last
        t = tg[j]
        if t == ON
            accum_line!(acc, cx, cy, xs[j], ys[j]); cx = xs[j]; cy = ys[j]; j += 1
        elseif t == CONIC
            if j < last && tg[j + 1] == ON
                accum_quad!(acc, cx, cy, xs[j], ys[j], xs[j + 1], ys[j + 1]); cx = xs[j + 1]; cy = ys[j + 1]; j += 2
            elseif j < last
                mx = 0.5f0 * (xs[j] + xs[j + 1]); my = 0.5f0 * (ys[j] + ys[j + 1])
                accum_quad!(acc, cx, cy, xs[j], ys[j], mx, my); cx = mx; cy = my; j += 1
            else
                accum_quad!(acc, cx, cy, xs[j], ys[j], sx, sy); cx = sx; cy = sy; j += 1
            end
        else
            (j + 1 <= last) || error("outline: incomplete cubic segment")
            ex, ey = j + 2 <= last ? (xs[j + 2], ys[j + 2]) : (sx, sy)
            accum_cubic!(acc, cx, cy, xs[j], ys[j], xs[j + 1], ys[j + 1], ex, ey); cx = ex; cy = ey; j += 3
        end
    end
    accum_line!(acc, cx, cy, sx, sy)
    return nothing
end

"""
    render_glyph(font, gid, pixel_size) -> (bitmap, left, top)

Render glyph `gid` at `pixel_size` pixels per em as FreeType's `FT_LOAD_RENDER` does (unhinted): `bitmap` is a
`width x rows` `Matrix{UInt8}` of coverage (row 1 is the top row), `left`/`top` are the bitmap's offsets from the
origin in pixels (`top` points up).
"""
function render_glyph(f::Font, gid::Int, pixel_size::Int)
    out = Outline()
    glyph_outline!(out, f, gid)
    n = npoints(out)
    n == 0 && return (Matrix{UInt8}(undef, 0, 0), 0, 0)
    scale = fixed_divfix(pixel_size * 64, f.units_per_em)
    # to 26.6 pixel coordinates (rounded as FT_MulFix)
    X = Vector{Int}(undef, n); Y = Vector{Int}(undef, n)
    for i in 1:n
        X[i] = fixed_mulfix(round(Int, out.x[i]), scale)
        Y[i] = fixed_mulfix(round(Int, out.y[i]), scale)
    end
    xmin = minimum(X); xmax = maximum(X); ymin = minimum(Y); ymax = maximum(Y)
    left = fld(xmin, 64); right = cld(xmax, 64)
    bottom = fld(ymin, 64); top = cld(ymax, 64)
    w = right - left; h = top - bottom
    (w > 0 && h > 0) || return (Matrix{UInt8}(undef, max(w, 0), max(h, 0)), left, top)
    xs = Vector{Float32}(undef, n); ys = Vector{Float32}(undef, n)
    for i in 1:n
        xs[i] = Float32(X[i] - 64left) / 64
        ys[i] = Float32(64top - Y[i]) / 64
    end
    acc = Accum(w, h)
    start = 1
    for e in out.ends
        accum_contour!(acc, xs, ys, out.tag, start, Int(e))
        start = Int(e) + 1
    end
    bmp = Matrix{UInt8}(undef, w, h)
    stride = w + 2
    for r in 1:h
        run = 0.0f0
        row = (r - 1) * stride
        for c in 1:w
            run += acc.a[row + c]
            cov = min(abs(run), 1.0f0)
            bmp[c, r] = UInt8(round(Int, cov * 255))
        end
    end
    return (bmp, left, top)
end
