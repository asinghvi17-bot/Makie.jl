# Compact Font Format (CFF 1) and its Type 2 charstrings. CFF2 is not supported.

"The parts of a CFF table needed to interpret a glyph's charstring."
struct CFFData
    off::Int                 # table offset in the font data; 0 when the font has no CFF table
    num_glyphs::Int
    charstrings::Int         # offset of the CharStrings INDEX
    gsubrs::Int              # offset of the global Subrs INDEX
    fdselect::Int            # offset of the FDSelect (0 when there is a single Private dict)
    lsubrs::Vector{Int}      # per font dict: offset of its local Subrs INDEX, 0 for none
    default_width::Vector{Float64}
    nominal_width::Vector{Float64}
end
CFFData() = CFFData(0, 0, 0, 0, 0, Int[], Float64[], Float64[])

# ---- INDEX ----
index_count(d::Vector{UInt8}, o::Int) = Int(u16(d, o))
function index_end(d::Vector{UInt8}, o::Int)
    n = index_count(d, o)
    n == 0 && return o + 2
    osz = Int(u8(d, o + 2))
    return o + 3 + (n + 1) * osz - 1 + _offset(d, o + 3 + n * osz, osz)
end
@inline function _offset(d::Vector{UInt8}, o::Int, osz::Int)
    v = 0
    for i in 0:osz - 1
        v = (v << 8) | Int(d[o + i + 1])
    end
    return v
end
"Absolute `(start, stop)` byte range (0-based, stop exclusive) of item `i` (0-based) of the INDEX at `o`."
function index_item(d::Vector{UInt8}, o::Int, i::Int)
    n = index_count(d, o)
    0 <= i < n || throw(BoundsError(d, o))
    osz = Int(u8(d, o + 2))
    base = o + 3 + (n + 1) * osz - 1
    return (base + _offset(d, o + 3 + i * osz, osz), base + _offset(d, o + 3 + (i + 1) * osz, osz))
end

# ---- DICT ----
"The operands of operator `op` in the DICT at `[s, e)` (two-byte operators `12 x` are `1200 + x`); empty if absent."
function dict_get(d::Vector{UInt8}, s::Int, e::Int, op::Int)
    ops = Float64[]
    p = s
    while p < e
        b = Int(u8(d, p))
        if b <= 21
            o = b
            p += 1
            if b == 12
                o = 1200 + Int(u8(d, p)); p += 1
            end
            o == op && return ops
            empty!(ops)
        elseif b == 28
            push!(ops, Float64(i16(d, p + 1))); p += 3
        elseif b == 29
            push!(ops, Float64(i32(d, p + 1))); p += 5
        elseif b == 30            # real number: packed nibbles, ended by 0xf
            p += 1
            fin = false
            while !fin
                v = u8(d, p); p += 1
                (v >> 4) == 0xf && (fin = true)
                (v & 0xf) == 0xf && (fin = true)
            end
            push!(ops, 0.0)
        elseif 32 <= b <= 246
            push!(ops, Float64(b - 139)); p += 1
        elseif 247 <= b <= 250
            push!(ops, Float64((b - 247) * 256 + Int(u8(d, p + 1)) + 108)); p += 2
        elseif 251 <= b <= 254
            push!(ops, Float64(-(b - 251) * 256 - Int(u8(d, p + 1)) - 108)); p += 2
        else
            error("CFF: bad DICT byte $b")
        end
    end
    return Float64[]
end

function read_private(d::Vector{UInt8}, dict_s::Int, dict_e::Int, cff::Int)
    pv = dict_get(d, dict_s, dict_e, 18)
    length(pv) == 2 || return (0, 0.0, 0.0)
    psize = Int(pv[1]); poff = cff + Int(pv[2])
    sub = dict_get(d, poff, poff + psize, 19)
    dw = dict_get(d, poff, poff + psize, 20)
    nw = dict_get(d, poff, poff + psize, 21)
    return (isempty(sub) ? 0 : poff + Int(sub[1]), isempty(dw) ? 0.0 : dw[1], isempty(nw) ? 0.0 : nw[1])
end

function parse_cff(d::Vector{UInt8}, cff::Int)
    u8(d, cff) == 1 || error("CFF: only version 1 is supported (CFF2 is not)")
    hdr = Int(u8(d, cff + 2))
    name_idx = cff + hdr
    top_idx = index_end(d, name_idx)
    str_idx = index_end(d, top_idx)
    gsubrs = index_end(d, str_idx)
    ts, te = index_item(d, top_idx, 0)
    cs = dict_get(d, ts, te, 17)
    isempty(cs) && error("CFF: no CharStrings")
    charstrings = cff + Int(cs[1])
    nglyphs = index_count(d, charstrings)
    lsubrs = Int[]; dws = Float64[]; nws = Float64[]
    fdselect = 0
    fda = dict_get(d, ts, te, 1236)
    if isempty(fda)       # not CID-keyed: one Private dict in the top DICT
        (sub, dw, nw) = read_private(d, ts, te, cff)
        push!(lsubrs, sub); push!(dws, dw); push!(nws, nw)
    else
        fdarray = cff + Int(fda[1])
        for i in 0:index_count(d, fdarray) - 1
            fs, fe = index_item(d, fdarray, i)
            (sub, dw, nw) = read_private(d, fs, fe, cff)
            push!(lsubrs, sub); push!(dws, dw); push!(nws, nw)
        end
        fds = dict_get(d, ts, te, 1237)
        isempty(fds) || (fdselect = cff + Int(fds[1]))
    end
    return CFFData(cff, nglyphs, charstrings, gsubrs, fdselect, lsubrs, dws, nws)
end

"Font dict index (0-based) of glyph `gid` (0-based)."
function fd_index(d::Vector{UInt8}, c::CFFData, gid::Int)
    c.fdselect == 0 && return 0
    fmt = u8(d, c.fdselect)
    fmt == 0 && return Int(u8(d, c.fdselect + 1 + gid))
    fmt == 3 || error("CFF: bad FDSelect format $fmt")
    nr = Int(u16(d, c.fdselect + 1))
    for r in 0:nr - 1
        first = Int(u16(d, c.fdselect + 3 + 3r))
        nxt = Int(u16(d, c.fdselect + 3 + 3(r + 1)))   # (the sentinel follows the last range)
        gid >= first && gid < nxt && return Int(u8(d, c.fdselect + 3 + 3r + 2))
    end
    return 0
end

# ---- Type 2 charstring interpreter ----
mutable struct CharString
    stack::Vector{Float64}
    sp::Int
    x::Float64
    y::Float64
    nstems::Int
    have_width::Bool
    open::Bool           # a contour has been started
    done::Bool
    gsubrs::Int
    lsubrs::Int
    out::Outline
end

@inline subr_bias(n::Int) = n < 1240 ? 107 : (n < 33900 ? 1131 : 32768)

@inline function cs_start!(st::CharString)
    if !st.open
        add_point!(st.out, st.x, st.y, ON)
        st.open = true
    end
    return nothing
end
@inline function cs_move!(st::CharString, dx, dy)
    if st.open
        close_contour!(st.out)
        st.open = false
    end
    st.x += dx; st.y += dy
    return nothing
end
@inline function cs_line!(st::CharString, dx, dy)
    cs_start!(st)
    st.x += dx; st.y += dy
    add_point!(st.out, st.x, st.y, ON)
    return nothing
end
@inline function cs_curve!(st::CharString, dx1, dy1, dx2, dy2, dx3, dy3)
    cs_start!(st)
    x1 = st.x + dx1; y1 = st.y + dy1
    x2 = x1 + dx2; y2 = y1 + dy2
    st.x = x2 + dx3; st.y = y2 + dy3
    add_point!(st.out, x1, y1, CUBIC)
    add_point!(st.out, x2, y2, CUBIC)
    add_point!(st.out, st.x, st.y, ON)
    return nothing
end

"Drop the optional leading width operand if the stack holds more operands than the operator takes (`n`)."
@inline function cs_width!(st::CharString, has::Bool)
    if !st.have_width
        st.have_width = true
        if has
            for i in 2:st.sp
                st.stack[i - 1] = st.stack[i]
            end
            st.sp -= 1
        end
    end
    return nothing
end

function cs_run!(st::CharString, d::Vector{UInt8}, s::Int, e::Int, depth::Int)
    depth > 10 && error("CFF: subroutine nesting too deep")
    p = s
    stk = st.stack
    while p < e && !st.done
        b = Int(u8(d, p)); p += 1
        if b >= 32 || b == 28
            st.sp < 192 || error("CFF: charstring stack overflow")
            st.sp += 1
            if b == 28
                stk[st.sp] = Float64(i16(d, p)); p += 2
            elseif b <= 246
                stk[st.sp] = Float64(b - 139)
            elseif b <= 250
                stk[st.sp] = Float64((b - 247) * 256 + Int(u8(d, p)) + 108); p += 1
            elseif b <= 254
                stk[st.sp] = Float64(-(b - 251) * 256 - Int(u8(d, p)) - 108); p += 1
            else
                stk[st.sp] = Float64(i32(d, p)) / 65536.0; p += 4
            end
            continue
        end
        sp = st.sp
        if b == 1 || b == 3 || b == 18 || b == 23          # hstem vstem hstemhm vstemhm
            cs_width!(st, isodd(st.sp))
            st.nstems += st.sp >> 1
            st.sp = 0
        elseif b == 19 || b == 20                           # hintmask cntrmask (implicit vstem)
            cs_width!(st, isodd(st.sp))
            st.nstems += st.sp >> 1
            st.sp = 0
            p += (st.nstems + 7) >> 3
        elseif b == 21                                      # rmoveto
            cs_width!(st, st.sp > 2)
            cs_move!(st, stk[st.sp - 1], stk[st.sp]); st.sp = 0
        elseif b == 22                                      # hmoveto
            cs_width!(st, st.sp > 1)
            cs_move!(st, stk[st.sp], 0.0); st.sp = 0
        elseif b == 4                                       # vmoveto
            cs_width!(st, st.sp > 1)
            cs_move!(st, 0.0, stk[st.sp]); st.sp = 0
        elseif b == 5                                       # rlineto
            i = 1
            while i + 1 <= sp
                cs_line!(st, stk[i], stk[i + 1]); i += 2
            end
            st.sp = 0
        elseif b == 6 || b == 7                             # hlineto vlineto
            horiz = b == 6
            for i in 1:sp
                horiz ? cs_line!(st, stk[i], 0.0) : cs_line!(st, 0.0, stk[i])
                horiz = !horiz
            end
            st.sp = 0
        elseif b == 8                                       # rrcurveto
            i = 1
            while i + 5 <= sp
                cs_curve!(st, stk[i], stk[i + 1], stk[i + 2], stk[i + 3], stk[i + 4], stk[i + 5]); i += 6
            end
            st.sp = 0
        elseif b == 24                                      # rcurveline
            i = 1
            while i + 7 <= sp
                cs_curve!(st, stk[i], stk[i + 1], stk[i + 2], stk[i + 3], stk[i + 4], stk[i + 5]); i += 6
            end
            cs_line!(st, stk[i], stk[i + 1])
            st.sp = 0
        elseif b == 25                                      # rlinecurve
            i = 1
            while i + 7 <= sp
                cs_line!(st, stk[i], stk[i + 1]); i += 2
            end
            cs_curve!(st, stk[i], stk[i + 1], stk[i + 2], stk[i + 3], stk[i + 4], stk[i + 5])
            st.sp = 0
        elseif b == 27                                      # hhcurveto
            i = 1; dy1 = 0.0
            if isodd(sp)
                dy1 = stk[1]; i = 2
            end
            while i + 3 <= sp
                cs_curve!(st, stk[i], dy1, stk[i + 1], stk[i + 2], stk[i + 3], 0.0); dy1 = 0.0; i += 4
            end
            st.sp = 0
        elseif b == 26                                      # vvcurveto
            i = 1; dx1 = 0.0
            if isodd(sp)
                dx1 = stk[1]; i = 2
            end
            while i + 3 <= sp
                cs_curve!(st, dx1, stk[i], stk[i + 1], stk[i + 2], 0.0, stk[i + 3]); dx1 = 0.0; i += 4
            end
            st.sp = 0
        elseif b == 30 || b == 31                           # vhcurveto hvcurveto
            horiz = b == 31
            i = 1
            while sp - i + 1 >= 4
                last = (sp - i + 1) == 5
                extra = last ? stk[i + 4] : 0.0
                if horiz
                    cs_curve!(st, stk[i], 0.0, stk[i + 1], stk[i + 2], extra, stk[i + 3])
                else
                    cs_curve!(st, 0.0, stk[i], stk[i + 1], stk[i + 2], stk[i + 3], extra)
                end
                horiz = !horiz; i += 4
            end
            st.sp = 0
        elseif b == 10 || b == 29                           # callsubr callgsubr
            sp >= 1 || error("CFF: callsubr on an empty stack")
            base = b == 10 ? st.lsubrs : st.gsubrs
            base == 0 && error("CFF: subroutine call without subrs")
            n = index_count(d, base)
            idx = Int(stk[sp]) + subr_bias(n)
            st.sp -= 1
            ss, se = index_item(d, base, idx)
            cs_run!(st, d, ss, se, depth + 1)
        elseif b == 11                                      # return
            return nothing
        elseif b == 14                                      # endchar
            cs_width!(st, sp == 1 || sp == 5)
            st.sp >= 4 && error("CFF: endchar-seac accents are not supported")
            if st.open
                close_contour!(st.out)
                st.open = false
            end
            st.done = true
        elseif b == 12
            b2 = Int(u8(d, p)); p += 1
            if b2 == 35                                     # flex
                cs_curve!(st, stk[1], stk[2], stk[3], stk[4], stk[5], stk[6])
                cs_curve!(st, stk[7], stk[8], stk[9], stk[10], stk[11], stk[12])
            elseif b2 == 34                                 # hflex
                cs_curve!(st, stk[1], 0.0, stk[2], stk[3], stk[4], 0.0)
                cs_curve!(st, stk[5], 0.0, stk[6], -stk[3], stk[7], 0.0)
            elseif b2 == 36                                 # hflex1
                cs_curve!(st, stk[1], stk[2], stk[3], stk[4], stk[5], 0.0)
                cs_curve!(st, stk[6], 0.0, stk[7], stk[8], stk[9], -(stk[2] + stk[4] + stk[8]))
            elseif b2 == 37                                 # flex1
                dx = stk[1] + stk[3] + stk[5] + stk[7] + stk[9]
                dy = stk[2] + stk[4] + stk[6] + stk[8] + stk[10]
                cs_curve!(st, stk[1], stk[2], stk[3], stk[4], stk[5], stk[6])
                if abs(dx) > abs(dy)
                    cs_curve!(st, stk[7], stk[8], stk[9], stk[10], stk[11], -dy)
                else
                    cs_curve!(st, stk[7], stk[8], stk[9], stk[10], -dx, stk[11])
                end
            else
                error("CFF: unsupported escape operator 12 $b2")
            end
            st.sp = 0
        else
            error("CFF: unsupported charstring operator $b")
        end
    end
    return nothing
end

"Append the outline of glyph `gid` (0-based) of the CFF font data `d` to `out`."
function cff_outline!(out::Outline, d::Vector{UInt8}, c::CFFData, gid::Int)
    0 <= gid < c.num_glyphs || throw(BoundsError(d, gid))
    fd = fd_index(d, c, gid)
    st = CharString(Vector{Float64}(undef, 192), 0, 0.0, 0.0, 0, false, false, false, c.gsubrs, c.lsubrs[fd + 1], out)
    s, e = index_item(d, c.charstrings, gid)
    cs_run!(st, d, s, e, 0)
    if st.open
        close_contour!(out)
    end
    return out
end
