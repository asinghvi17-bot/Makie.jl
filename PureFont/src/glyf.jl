# TrueType outlines: `loca` + `glyf`, simple and composite glyphs.

"Byte range `[s, e)` of glyph `gid`'s data in the font data (empty if the glyph has no outline)."
function glyf_range(f::Font, gid::Int)
    0 <= gid < f.num_glyphs || throw(BoundsError(f.data, gid))
    d = f.data
    if f.loca_long
        s = Int(u32(d, f.loca + 4gid)); e = Int(u32(d, f.loca + 4gid + 4))
    else
        s = 2 * Int(u16(d, f.loca + 2gid)); e = 2 * Int(u16(d, f.loca + 2gid + 2))
    end
    return (f.glyf + s, f.glyf + e)
end

function glyf_outline!(out::Outline, f::Font, gid::Int, depth::Int)
    depth > 8 && error("glyf: composite nesting too deep")
    s, e = glyf_range(f, gid)
    e > s || return out
    d = f.data
    nc = Int(i16(d, s))
    if nc >= 0
        glyf_simple!(out, d, s, nc)
    else
        glyf_composite!(out, f, s, e, depth)
    end
    return out
end

function glyf_simple!(out::Outline, d::Vector{UInt8}, s::Int, nc::Int)
    nc == 0 && return out
    p = s + 10
    base = npoints(out); cbase = length(out.ends)
    last = -1
    for i in 0:nc - 1
        last = Int(u16(d, p + 2i))
    end
    npts = last + 1
    p += 2nc
    p += 2 + Int(u16(d, p))                      # instructions (not executed)
    flags = Vector{UInt8}(undef, npts)
    i = 1
    while i <= npts
        fl = u8(d, p); p += 1
        flags[i] = fl; i += 1
        if fl & 0x08 != 0
            rep = Int(u8(d, p)); p += 1
            for _ in 1:rep
                i <= npts || error("glyf: bad flag repeat")
                flags[i] = fl; i += 1
            end
        end
    end
    x = 0
    xs = Vector{Int}(undef, npts)
    for i in 1:npts
        fl = flags[i]
        if fl & 0x02 != 0
            dx = Int(u8(d, p)); p += 1
            x += (fl & 0x10 != 0) ? dx : -dx
        elseif fl & 0x10 == 0
            x += Int(i16(d, p)); p += 2
        end
        xs[i] = x
    end
    y = 0
    for i in 1:npts
        fl = flags[i]
        if fl & 0x04 != 0
            dy = Int(u8(d, p)); p += 1
            y += (fl & 0x20 != 0) ? dy : -dy
        elseif fl & 0x20 == 0
            y += Int(i16(d, p)); p += 2
        end
        add_point!(out, xs[i], y, (fl & 0x01 != 0) ? ON : CONIC)
    end
    for i in 0:nc - 1
        push!(out.ends, Int32(base + Int(u16(d, s + 10 + 2i)) + 1))
    end
    return out
end

function glyf_composite!(out::Outline, f::Font, s::Int, e::Int, depth::Int)
    d = f.data
    p = s + 10
    sub = Outline()
    while true
        fl = Int(u16(d, p)); gi = Int(u16(d, p + 2)); p += 4
        local a1::Int, a2::Int
        if fl & 0x0001 != 0                      # ARG_1_AND_2_ARE_WORDS
            if fl & 0x0002 != 0
                a1 = Int(i16(d, p)); a2 = Int(i16(d, p + 2))
            else
                a1 = Int(u16(d, p)); a2 = Int(u16(d, p + 2))
            end
            p += 4
        else
            if fl & 0x0002 != 0
                a1 = Int(reinterpret(Int8, d[p + 1])); a2 = Int(reinterpret(Int8, d[p + 2]))
            else
                a1 = Int(d[p + 1]); a2 = Int(d[p + 2])
            end
            p += 2
        end
        fl & 0x0002 != 0 || error("glyf: composite glyphs positioned by point matching are not supported")
        a = 65536; b = 0; c = 0; dd = 65536     # 16.16 matrix; xx, yx, xy, yy in file order
        if fl & 0x0008 != 0                      # WE_HAVE_A_SCALE
            a = dd = 4 * Int(i16(d, p)); p += 2
        elseif fl & 0x0040 != 0                  # WE_HAVE_AN_X_AND_Y_SCALE
            a = 4 * Int(i16(d, p)); dd = 4 * Int(i16(d, p + 2)); p += 4
        elseif fl & 0x0080 != 0                  # WE_HAVE_A_TWO_BY_TWO
            a = 4 * Int(i16(d, p)); b = 4 * Int(i16(d, p + 2))
            c = 4 * Int(i16(d, p + 4)); dd = 4 * Int(i16(d, p + 6)); p += 8
        end
        empty!(sub)
        glyf_outline!(sub, f, gi, depth + 1)
        base = npoints(out)
        for i in 1:npoints(sub)
            x = Int(sub.x[i]); y = Int(sub.y[i])
            # (FreeType rounds each product, FT_MulFix, before adding the offset)
            add_point!(out, fixed_mulfix(x, a) + fixed_mulfix(y, c) + a1, fixed_mulfix(x, b) + fixed_mulfix(y, dd) + a2, sub.tag[i])
        end
        for en in sub.ends
            push!(out.ends, Int32(base + en))
        end
        fl & 0x0020 != 0 || break               # MORE_COMPONENTS
    end
    return out
end
